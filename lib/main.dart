import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'models/interview_models.dart';
import 'services/gemini_live_service.dart';
import 'services/interview_summary_service.dart';
import 'services/mlkit_native_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GeminiInterviewApp());
}

class GeminiInterviewApp extends StatelessWidget {
  const GeminiInterviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemini Live 60-Min Interview Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const InterviewHomePage(),
    );
  }
}

class InterviewHomePage extends StatefulWidget {
  const InterviewHomePage({super.key});

  @override
  State<InterviewHomePage> createState() => _InterviewHomePageState();
}

class _InterviewHomePageState extends State<InterviewHomePage> {
  static const Duration _maxSessionDuration = Duration(minutes: 60);

  final _apiKeyController = TextEditingController(
    text: const String.fromEnvironment('GEMINI_API_KEY'),
  );
  final _recorder = AudioRecorder();
  final _geminiLive = GeminiLiveService();
  final _mlKitBridge = MlKitNativeBridge();
  late final InterviewSummaryService _summaryService =
      InterviewSummaryService(_mlKitBridge);

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<MlKitEvent>? _mlKitSub;
  StreamSubscription<Uint8List>? _pcmOutSub;
  Timer? _sessionTimer;

  final List<TranscriptEntry> _entries = [];
  Map<String, String> _speakerRoleLabels = {};
  String _livePartialText = '';
  String _activeDetectedSpeaker = 'Speaker 1';
  String _statusBanner = 'Ready for up to 60-minute live interview';
  Duration _elapsed = Duration.zero;
  bool _isStreaming = false;
  bool _isGeneratingSummary = false;
  bool _aiCoInterviewerEnabled = true;

  @override
  void initState() {
    super.initState();
    _bindStreams();
  }

  void _bindStreams() {
    // 1. Native Android ML Kit On-Device Speech + Acoustic Speaker Diarizer events
    _mlKitSub = _mlKitBridge.events.listen((event) {
      if (!mounted) return;
      if (event.type == 'transcript') {
        final speaker = event.speaker ?? 'Speaker 1';
        setState(() {
          _activeDetectedSpeaker = speaker;
          if (event.isFinal && (event.text?.trim().isNotEmpty ?? false)) {
            _livePartialText = '';
            _entries.add(
              TranscriptEntry(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                speaker: _speakerRoleLabels[speaker] ?? speaker,
                text: event.text!.trim(),
                timestamp: DateTime.now(),
                isOnDeviceMlKit: true,
              ),
            );
          } else {
            _livePartialText = '[${_speakerRoleLabels[speaker] ?? speaker}] ${event.text ?? ''}';
          }
        });
      } else if (event.message != null) {
        setState(() => _statusBanner = event.message!);
      }
    });

    // 2. Gemini Live cloud input transcription fallback (tagged with active diarized speaker)
    _geminiLive.userTranscriptStream.listen((cloudText) {
      if (!mounted) return;
      final isDuplicate = _entries.isNotEmpty &&
          !_entries.last.isFromGeminiModel &&
          _entries.last.text.toLowerCase() == cloudText.toLowerCase();
      if (!isDuplicate) {
        final spk = _speakerRoleLabels[_activeDetectedSpeaker] ?? _activeDetectedSpeaker;
        setState(() {
          _entries.add(
            TranscriptEntry(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              speaker: spk,
              text: cloudText,
              timestamp: DateTime.now(),
            ),
          );
        });
      }
    });

    // 3. Gemini Live spoken response transcription
    _geminiLive.modelTranscriptStream.listen((aiText) {
      if (!mounted) return;
      setState(() {
        if (_entries.isNotEmpty && _entries.last.isFromGeminiModel) {
          final prev = _entries.removeLast();
          _entries.add(
            TranscriptEntry(
              id: prev.id,
              speaker: 'Gemini AI',
              text: '${prev.text} $aiText'.trim(),
              timestamp: prev.timestamp,
              isFromGeminiModel: true,
            ),
          );
        } else {
          _entries.add(
            TranscriptEntry(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              speaker: 'Gemini AI',
              text: aiText,
              timestamp: DateTime.now(),
              isFromGeminiModel: true,
            ),
          );
        }
      });
    });

    // 4. Play 24kHz PCM voice output from Gemini Live via native Android AudioTrack
    _pcmOutSub = _geminiLive.pcm24kOutputStream.listen((Uint8List rawBytes) async {
      await _mlKitBridge.playModelPcm24k(rawBytes);
    });

    // 5. Handle barge-in interruption
    _geminiLive.onInterrupted.listen((_) async {
      await _mlKitBridge.clearModelAudio();
    });

    _geminiLive.statusStream.listen((s) {
      if (mounted) setState(() => _statusBanner = s);
    });
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '60:00';
    }
    return '$m:$s';
  }

  Future<void> _toggleSession() async {
    if (_isStreaming) {
      await _stopSession(autoReached60Min: false);
    } else {
      await _startSession();
    }
  }

  Future<void> _startSession() async {
    final hasMic = await _recorder.hasPermission();
    if (!hasMic) {
      setState(() => _statusBanner = 'Microphone permission is required.');
      return;
    }

    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isNotEmpty) {
      try {
        await _geminiLive.connect(
          apiKey: apiKey,
          aiCoInterviewerMode: _aiCoInterviewerEnabled,
        );
      } catch (e) {
        setState(() => _statusBanner = 'Cloud connect failed ($e) — running On-Device ML Kit only.');
      }
    } else {
      setState(() => _statusBanner = 'No API key — running 60-min On-Device ML Kit + Diarizer offline.');
    }

    await _mlKitBridge.startOnDeviceStt();

    const config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
    );

    final micStream = await _recorder.startStream(config);
    _micSub = micStream.listen((Uint8List pcmChunk) {
      _geminiLive.sendAudioChunk16k(pcmChunk);
      _mlKitBridge.feedPcmChunk(pcmChunk);
    });

    _sessionTimer?.cancel();
    _elapsed = Duration.zero;
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _elapsed += const Duration(seconds: 1);
      });
      if (_elapsed >= _maxSessionDuration) {
        _stopSession(autoReached60Min: true);
      }
    });

    setState(() => _isStreaming = true);
  }

  Future<void> _stopSession({required bool autoReached60Min}) async {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    await _recorder.stop();
    await _mlKitBridge.stopOnDeviceStt();
    await _geminiLive.disconnect();

    if (!mounted) return;
    setState(() {
      _isStreaming = false;
      _livePartialText = '';
      _statusBanner = autoReached60Min
          ? '60-minute interview complete! Generating summary...'
          : 'Interview paused (${_formatDuration(_elapsed)} elapsed). Tap Summarize for report.';
    });

    if (autoReached60Min && _entries.isNotEmpty) {
      await _generateSummary();
    }
  }

  Future<void> _generateSummary() async {
    if (_entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Record at least a few utterances first.')),
      );
      return;
    }

    setState(() => _isGeneratingSummary = true);
    try {
      final summary = await _summaryService.generateHybridSummary(
        apiKey: _apiKeyController.text.trim(),
        entries: _entries,
      );

      if (summary.speakerRoles.isNotEmpty) {
        setState(() {
          _speakerRoleLabels = summary.speakerRoles;
          for (final entry in _entries) {
            if (summary.speakerRoles.containsKey(entry.speaker)) {
              entry.speaker = '${entry.speaker} (${summary.speakerRoles[entry.speaker]})';
            }
          }
        });
      }

      if (!mounted) return;
      _showSummarySheet(summary);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Summary error: $e')),
      );
    } finally {
      if (mounted) setState(() => _isGeneratingSummary = false);
    }
  }

  void _showSummarySheet(InterviewSummaryResult summary) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        maxChildSize: 0.95,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            Text('Interview Summary Report (${_formatDuration(_elapsed)})',
                style: Theme.of(ctx).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'On-Device ML Kit (Gemini Nano / AICore)',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.tealAccent),
                    ),
                    const SizedBox(height: 6),
                    Text(summary.onDeviceBullets ?? 'Not available'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Hiring Signal: ${summary.hiringRecommendation}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 10),
            Text(summary.executiveSummary),
            if (summary.speakerRoles.isNotEmpty) ...[
              const Divider(height: 24),
              const Text('Diarized Speaker Attribution',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              ...summary.speakerRoles.entries
                  .map((e) => Text('• ${e.key}: ${e.value}')),
            ],
            if (summary.keyStrengths.isNotEmpty) ...[
              const Divider(height: 24),
              const Text('Key Candidate Strengths',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              ...summary.keyStrengths.map((s) => Text('• $s')),
            ],
            if (summary.followUpQuestions.isNotEmpty) ...[
              const Divider(height: 24),
              const Text('Recommended Follow-up Questions',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              ...summary.followUpQuestions.map((q) => Text('• $q')),
            ],
          ],
        ),
      ),
    );
  }

  Color _speakerColor(TranscriptEntry entry) {
    if (entry.isFromGeminiModel) return Colors.purpleAccent.shade100;
    if (entry.speaker.startsWith('Speaker 1')) return Colors.lightBlueAccent;
    if (entry.speaker.startsWith('Speaker 2')) return Colors.amberAccent;
    return Colors.greenAccent;
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    _micSub?.cancel();
    _mlKitSub?.cancel();
    _pcmOutSub?.cancel();
    _recorder.dispose();
    _geminiLive.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_elapsed.inSeconds / _maxSessionDuration.inSeconds).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemini Live + ML Kit (60m)'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '${_formatDuration(_elapsed)} / 60:00',
                style: TextStyle(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.bold,
                  color: _isStreaming ? Colors.greenAccent : Colors.white70,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Generate Interview Summary',
            onPressed: _isGeneratingSummary ? null : _generateSummary,
            icon: _isGeneratingSummary
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.summarize_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: LinearProgressIndicator(value: progress),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _apiKeyController,
              obscureText: true,
              enabled: !_isStreaming,
              decoration: const InputDecoration(
                labelText: 'Gemini API Key (leave blank for Offline ML Kit mode)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('AI Co-Interviewer Voice Responses'),
            subtitle: Text(_statusBanner, maxLines: 1, overflow: TextOverflow.ellipsis),
            value: _aiCoInterviewerEnabled,
            onChanged: _isStreaming
                ? null
                : (v) => setState(() => _aiCoInterviewerEnabled = v),
          ),
          const Divider(height: 1),
          Expanded(
            child: _entries.isEmpty && _livePartialText.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Tap "Start 60-Min Interview" to stream 16kHz audio to Gemini Live '
                        '(with slidingWindow compression + sessionResumption) and on-device '
                        'Android ML Kit with live speaker diarization.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _entries.length + (_livePartialText.isNotEmpty ? 1 : 0),
                    itemBuilder: (ctx, idx) {
                      if (idx == _entries.length) {
                        return Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text(
                            _livePartialText,
                            style: const TextStyle(
                              fontStyle: FontStyle.italic,
                              color: Colors.white70,
                            ),
                          ),
                        );
                      }
                      final item = _entries[idx];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          dense: true,
                          title: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: _speakerColor(item).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  item.speaker,
                                  style: TextStyle(
                                    color: _speakerColor(item),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                item.isOnDeviceMlKit ? 'On-Device ML Kit' : 'Gemini Live',
                                style: const TextStyle(fontSize: 11, color: Colors.white54),
                              ),
                            ],
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(item.text, style: const TextStyle(fontSize: 14)),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: _isStreaming ? Colors.redAccent : null,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _toggleSession,
                      icon: Icon(_isStreaming ? Icons.stop_circle : Icons.mic),
                      label: Text(_isStreaming ? 'Stop Live Interview' : 'Start 60-Min Interview'),
                    ),
                  ),
                  if (_isStreaming && _geminiLive.isConnected) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _geminiLive.sendTextPrompt(
                        'Based on the interview so far, suggest one sharp follow-up question.',
                      ),
                      icon: const Icon(Icons.psychology_alt),
                      label: const Text('Ask AI'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
