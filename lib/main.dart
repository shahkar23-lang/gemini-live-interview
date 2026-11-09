import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      title: 'Journalist 60-Min Live Interview Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const InterviewHomePage(),
    );
  }
}

enum SpeakerOverride { autoDetect, journalist, interviewee }

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
  final _scrollController = ScrollController();
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
  List<String> _summaryBullets = const [
    'Tap the green "START 60-MIN HANDS-FREE MIC" button once and speak naturally.',
    'Live summary bullets will update here automatically as the interview progresses.'
  ];
  List<String> _counterQuestions = const [
    'Counter-questions for the journalist will appear here automatically based on live transcription.',
    'Tap "Refresh Counter-Questions" anytime to challenge the interviewee\'s latest statement.'
  ];
  String _analysisSource = 'Ready';
  String _livePartialText = '';
  String _activeDetectedSpeaker = 'Speaker 2 (Interviewee)';
  SpeakerOverride _speakerOverride = SpeakerOverride.autoDetect;
  String _statusBanner = 'Tap the Mic button ONCE to start hands-free 60-min recording';
  double _micLevelNormalized = 0.0;
  Duration _elapsed = Duration.zero;
  bool _isStreaming = false;
  bool _isAnalyzing = false;
  bool _enableGeminiVoiceStream = false;

  @override
  void initState() {
    super.initState();
    _bindStreams();
  }

  String _resolveActiveSpeaker(String detected) {
    switch (_speakerOverride) {
      case SpeakerOverride.journalist:
        return 'Speaker 1 (Journalist)';
      case SpeakerOverride.interviewee:
        return 'Speaker 2 (Interviewee)';
      case SpeakerOverride.autoDetect:
        return detected;
    }
  }

  void _bindStreams() {
    // 1. Native Android Continuous Speech + Acoustic Speaker Diarizer events
    _mlKitSub = _mlKitBridge.events.listen((event) {
      if (!mounted) return;
      if (event.type == 'rms') {
        final db = event.rmsdB ?? 0.0;
        final norm = ((db + 2.0) / 12.0).clamp(0.05, 1.0);
        setState(() => _micLevelNormalized = norm);
        return;
      }

      if (event.type == 'transcript') {
        final speaker = _resolveActiveSpeaker(
          event.speaker ?? 'Speaker 2 (Interviewee)',
        );
        setState(() {
          _activeDetectedSpeaker = speaker;
          if (event.isFinal && (event.text?.trim().isNotEmpty ?? false)) {
            _livePartialText = '';
            _entries.add(
              TranscriptEntry(
                id: DateTime.now().microsecondsSinceEpoch.toString(),
                speaker: speaker,
                text: event.text!.trim(),
                timestamp: DateTime.now(),
                sessionOffset: _elapsed,
                isOnDeviceMlKit: true,
              ),
            );
            _scrollToBottom();
            // Auto-update journalist counter-questions & summary every 2 finalized turns
            if (_entries.length == 1 || _entries.length % 2 == 0) {
              _refreshSummaryAndCounterQuestions();
            }
          } else if ((event.text?.trim().isNotEmpty ?? false)) {
            _livePartialText = event.text!.trim();
          }
        });
      } else if (event.message != null) {
        setState(() => _statusBanner = event.message!);
      }
    });

    // 2. Gemini Live cloud input transcription (when Gemini Live WebSocket is enabled)
    _geminiLive.userTranscriptStream.listen((cloudText) {
      if (!mounted) return;
      final isDuplicate = _entries.isNotEmpty &&
          !_entries.last.isFromGeminiModel &&
          _entries.last.text.toLowerCase() == cloudText.toLowerCase();
      if (!isDuplicate) {
        final spk = _resolveActiveSpeaker(_activeDetectedSpeaker);
        setState(() {
          _entries.add(
            TranscriptEntry(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              speaker: spk,
              text: cloudText,
              timestamp: DateTime.now(),
              sessionOffset: _elapsed,
            ),
          );
        });
        _scrollToBottom();
        if (_entries.length == 1 || _entries.length % 2 == 0) {
          _refreshSummaryAndCounterQuestions();
        }
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
              speaker: 'Gemini AI Co-Host',
              text: '${prev.text} $aiText'.trim(),
              timestamp: prev.timestamp,
              sessionOffset: prev.sessionOffset,
              isFromGeminiModel: true,
            ),
          );
        } else {
          _entries.add(
            TranscriptEntry(
              id: DateTime.now().microsecondsSinceEpoch.toString(),
              speaker: 'Gemini AI Co-Host',
              text: aiText,
              timestamp: DateTime.now(),
              sessionOffset: _elapsed,
              isFromGeminiModel: true,
            ),
          );
        }
      });
      _scrollToBottom();
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _formatDuration(Duration d) {
    if (d >= _maxSessionDuration) return '60:00';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
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
    // 1. Request microphone permission natively on Android
    final granted = await _mlKitBridge.ensureMicPermission();
    if (!granted) {
      setState(() {
        _statusBanner = 'Microphone permission denied. Please allow Microphone access.';
      });
      return;
    }

    // 2. Immediately latch UI into Hands-Free Recording state (no holding needed!)
    _sessionTimer?.cancel();
    setState(() {
      _isStreaming = true;
      _statusBanner = 'LIVE HANDS-FREE RECORDING — Speak naturally (up to 60 mins)';
    });

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _elapsed += const Duration(seconds: 1);
      });
      if (_elapsed >= _maxSessionDuration) {
        _stopSession(autoReached60Min: true);
      }
    });

    final apiKey = _apiKeyController.text.trim();
    final useGeminiVoiceStream = _enableGeminiVoiceStream && apiKey.isNotEmpty;

    // 3. Start Native Android Continuous Speech Recognition + Diarizer immediately
    await _mlKitBridge.startOnDeviceStt(usePfdPipe: useGeminiVoiceStream);

    // 4. Only open Flutter PCM mic stream if user explicitly enabled 2-way Gemini Live Voice Stream
    if (useGeminiVoiceStream) {
      try {
        await _geminiLive.connect(
          apiKey: apiKey,
          aiCoInterviewerMode: true,
        );
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
      } catch (e) {
        // Fall back cleanly to on-device continuous STT without interrupting recording
        await _mlKitBridge.startOnDeviceStt(usePfdPipe: false);
      }
    }
  }

  Future<void> _stopSession({required bool autoReached60Min}) async {
    _sessionTimer?.cancel();
    _sessionTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _mlKitBridge.stopOnDeviceStt();
    await _geminiLive.disconnect();

    if (!mounted) return;
    setState(() {
      _isStreaming = false;
      _micLevelNormalized = 0.0;
      if (_livePartialText.trim().isNotEmpty) {
        _entries.add(
          TranscriptEntry(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            speaker: _resolveActiveSpeaker(_activeDetectedSpeaker),
            text: _livePartialText.trim(),
            timestamp: DateTime.now(),
            sessionOffset: _elapsed,
            isOnDeviceMlKit: true,
          ),
        );
        _livePartialText = '';
      }
      _statusBanner = autoReached60Min
          ? '60-minute session completed!'
          : 'Recording paused at ${_formatDuration(_elapsed)}. Tap Mic once to resume.';
    });

    if (_entries.isNotEmpty) {
      await _refreshSummaryAndCounterQuestions();
    }
  }

  Future<void> _refreshSummaryAndCounterQuestions() async {
    if (_entries.isEmpty || _isAnalyzing) return;
    setState(() => _isAnalyzing = true);
    try {
      final result = await _summaryService.generateJournalistBrief(
        apiKey: _apiKeyController.text.trim(),
        entries: _entries,
      );
      if (!mounted) return;
      setState(() {
        _summaryBullets = result.summaryBullets;
        _counterQuestions = result.journalistCounterQuestions;
        _analysisSource = result.sourceLabel;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusBanner = 'Analysis note: $e');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  void _openSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text('Gemini Cloud & Audio Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Live Transcription, Summarization, and Journalist Counter-Questions work out-of-the-box on your phone! '
                'Optionally add a Gemini API Key for cloud-enhanced analysis:',
                style: TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Gemini API Key (Optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Gemini Live 2-Way Voice Stream',
                  style: TextStyle(fontSize: 13.5),
                ),
                subtitle: const Text(
                  'Enable only if using headphones and an API key',
                  style: TextStyle(fontSize: 11.5),
                ),
                value: _enableGeminiVoiceStream,
                onChanged: (val) {
                  setModalState(() => _enableGeminiVoiceStream = val);
                  setState(() => _enableGeminiVoiceStream = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Color _speakerColor(String speaker) {
    if (speaker.contains('Gemini')) return Colors.purpleAccent;
    if (speaker.contains('Journalist') || speaker.contains('Speaker 1')) {
      return Colors.cyanAccent;
    }
    return Colors.amberAccent;
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    _micSub?.cancel();
    _mlKitSub?.cancel();
    _pcmOutSub?.cancel();
    _scrollController.dispose();
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
        titleSpacing: 12,
        title: const Text(
          'Journalist Live Interview Studio',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isStreaming
                  ? Colors.redAccent.withValues(alpha: 0.25)
                  : Colors.white10,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isStreaming ? Colors.redAccent : Colors.white24,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isStreaming ? Icons.fiber_manual_record : Icons.timer_outlined,
                  size: 14,
                  color: _isStreaming ? Colors.redAccent : Colors.white70,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_formatDuration(_elapsed)} / 60:00',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Reset Session',
            onPressed: () {
              setState(() {
                _entries.clear();
                _livePartialText = '';
                _elapsed = Duration.zero;
              });
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: 'Settings & API Key',
            onPressed: _openSettingsDialog,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.white12,
            color: _isStreaming ? Colors.redAccent : Colors.cyanAccent,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ===================================================================
            // HANDS-FREE 1-TAP LATCH MICROPHONE BAR (NO NEED TO HOLD!)
            // ===================================================================
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              decoration: BoxDecoration(
                color: _isStreaming
                    ? const Color(0xFF2A1215)
                    : const Color(0xFF141D26),
                border: Border(
                  bottom: BorderSide(
                    color: _isStreaming ? Colors.redAccent : Colors.cyanAccent.withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                ),
              ),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            _isStreaming ? Colors.redAccent.shade700 : Colors.tealAccent.shade700,
                        foregroundColor: _isStreaming ? Colors.white : Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _toggleSession,
                      icon: Icon(
                        _isStreaming ? Icons.pause_circle_filled : Icons.mic,
                        size: 26,
                      ),
                      label: Text(
                        _isStreaming
                            ? '● HANDS-FREE RECORDING ON (TAP ONCE TO PAUSE)'
                            : 'TAP ONCE TO START 60-MIN HANDS-FREE MIC',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Text(
                        'Mic Level:',
                        style: TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            minHeight: 6,
                            value: _isStreaming ? _micLevelNormalized : 0.0,
                            backgroundColor: Colors.white12,
                            color: Colors.greenAccent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Speaker Diarization Quick Selector
                      SegmentedButton<SpeakerOverride>(
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: SpeakerOverride.autoDetect,
                            label: Text('Auto', style: TextStyle(fontSize: 11)),
                          ),
                          ButtonSegment(
                            value: SpeakerOverride.journalist,
                            label: Text('Journalist', style: TextStyle(fontSize: 11)),
                          ),
                          ButtonSegment(
                            value: SpeakerOverride.interviewee,
                            label: Text('Guest', style: TextStyle(fontSize: 11)),
                          ),
                        ],
                        selected: {_speakerOverride},
                        onSelectionChanged: (s) {
                          setState(() => _speakerOverride = s.first);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ===================================================================
            // SECTION 1: PROMINENT LIVE TRANSCRIPTION AREA
            // ===================================================================
            Expanded(
              flex: 5,
              child: Container(
                margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF10141C),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isStreaming ? Colors.cyanAccent : Colors.white24,
                    width: _isStreaming ? 1.6 : 1.0,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header bar
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: const BoxDecoration(
                        color: Color(0xFF1B2432),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.closed_caption, color: Colors.cyanAccent, size: 18),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              'LIVE TRANSCRIPTION (SPEAKER DIARIZED)',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                                color: Colors.cyanAccent,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                          Text(
                            '${_entries.length} turns',
                            style: const TextStyle(fontSize: 11, color: Colors.white60),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () {
                              final allText = _entries
                                  .map((e) => '[${_formatDuration(e.sessionOffset)}] ${e.speaker}: ${e.text}')
                                  .join('\n');
                              Clipboard.setData(ClipboardData(text: allText));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Full transcript copied to clipboard')),
                              );
                            },
                            child: const Icon(Icons.copy, size: 16, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),

                    // Prominent Real-Time Live Caption Banner (shows words as you speak!)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      color: const Color(0xFF16202E),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _isStreaming ? Icons.graphic_eq : Icons.mic_none,
                            color: _isStreaming ? Colors.greenAccent : Colors.white38,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _livePartialText.isNotEmpty
                                  ? '${_resolveActiveSpeaker(_activeDetectedSpeaker)}: "$_livePartialText..."'
                                  : (_isStreaming
                                      ? 'Listening hands-free... Speak now and live words will appear here immediately.'
                                      : _statusBanner),
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: _livePartialText.isNotEmpty
                                    ? FontWeight.w700
                                    : FontWeight.normal,
                                color: _livePartialText.isNotEmpty
                                    ? Colors.greenAccent
                                    : Colors.white70,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // Scrollable Diarized Transcript Log
                    Expanded(
                      child: _entries.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  _isStreaming
                                      ? '🎤 Recording is LIVE & Hands-Free!\nSpeak into your phone — every sentence is transcribed & speaker-labeled here automatically.'
                                      : 'Tap the green "TAP ONCE TO START 60-MIN HANDS-FREE MIC" button above.\nYou do NOT need to hold the button.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(10),
                              itemCount: _entries.length,
                              itemBuilder: (ctx, idx) {
                                final item = _entries[idx];
                                final color = _speakerColor(item.speaker);
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '[${_formatDuration(item.sessionOffset)}] ',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.white38,
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          item.speaker,
                                          style: TextStyle(
                                            color: color,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          item.text,
                                          style: const TextStyle(
                                            fontSize: 13.5,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),

            // ===================================================================
            // SECTION 2 & 3: JOURNALIST COUNTER-QUESTIONS & LIVE SUMMARIZATION
            // ===================================================================
            Expanded(
              flex: 5,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                children: [
                  // --- JOURNALIST COUNTER-QUESTIONS CARD ---
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1726),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.psychology_alt, color: Colors.amberAccent, size: 19),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                'JOURNALIST COUNTER-QUESTIONS',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12.5,
                                  color: Colors.amberAccent,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                              ),
                              onPressed:
                                  _isAnalyzing ? null : _refreshSummaryAndCounterQuestions,
                              icon: _isAnalyzing
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.bolt, size: 15),
                              label: const Text('Ask Counter', style: TextStyle(fontSize: 11.5)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ..._counterQuestions.asMap().entries.map(
                              (q) => Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Q${q.key + 1}. ',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.amberAccent,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        q.value,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          color: Colors.white,
                                          height: 1.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // --- LIVE INTERVIEW SUMMARIZATION CARD ---
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF132226),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.6)),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.summarize, color: Colors.tealAccent, size: 18),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'INTERVIEW SUMMARY ($_analysisSource)',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12.5,
                                  color: Colors.tealAccent,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                              ),
                              onPressed:
                                  _isAnalyzing ? null : _refreshSummaryAndCounterQuestions,
                              icon: const Icon(Icons.refresh, size: 15),
                              label: const Text('Summarize', style: TextStyle(fontSize: 11.5)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ..._summaryBullets.map(
                          (b) => Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '• ',
                                  style: TextStyle(
                                    color: Colors.tealAccent,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    b,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Colors.white,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
