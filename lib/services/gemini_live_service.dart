import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

class GeminiLiveService {
  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  bool _isConnected = false;

  bool get isConnected => _isConnected;

  final _pcmOutputController = StreamController<Uint8List>.broadcast();
  final _userTranscriptController = StreamController<String>.broadcast();
  final _modelTranscriptController = StreamController<String>.broadcast();
  final _interruptedController = StreamController<void>.broadcast();
  final _statusController = StreamController<String>.broadcast();

  Stream<Uint8List> get pcm24kOutputStream => _pcmOutputController.stream;
  Stream<String> get userTranscriptStream => _userTranscriptController.stream;
  Stream<String> get modelTranscriptStream => _modelTranscriptController.stream;
  Stream<void> get onInterrupted => _interruptedController.stream;
  Stream<String> get statusStream => _statusController.stream;

  Future<void> connect({
    required String apiKey,
    String model = 'models/gemini-2.5-flash',
    String voiceName = 'Aoede',
    bool aiCoInterviewerMode = true,
  }) async {
    await disconnect();

    final uri = Uri.parse(
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
      '?key=$apiKey',
    );

    _statusController.add('Connecting to Gemini Live...');
    _channel = WebSocketChannel.connect(uri);
    await _channel!.ready;
    _isConnected = true;

    final systemPrompt = aiCoInterviewerMode
        ? 'You are an expert technical co-interviewer listening to a live interview. '
          'Keep spoken replies concise (1-2 sentences) and only chime in when addressed '
          'or asked for a follow-up question.'
        : 'Listen quietly to the interview conversation without interrupting unless explicitly asked.';

    // 1. Send BidiGenerateContentSetup payload
    final setupPayload = {
      'setup': {
        'model': model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voiceName},
            },
          },
        },
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt}
          ],
        },
        'inputAudioTranscription': {},
        'outputAudioTranscription': {},
      },
    };

    _channel!.sink.add(jsonEncode(setupPayload));
    _statusController.add('Gemini Live connected');

    // 2. Listen to serverContent frames
    _wsSub = _channel!.stream.listen(
      (rawEvent) {
        final jsonStr = rawEvent is Uint8List ? utf8.decode(rawEvent) : rawEvent.toString();
        final Map<String, dynamic> data = jsonDecode(jsonStr) as Map<String, dynamic>;
        _handleServerMessage(data);
      },
      onError: (e) {
        _isConnected = false;
        _statusController.add('Gemini Live error: $e');
      },
      onDone: () {
        _isConnected = false;
        _statusController.add('Gemini Live session closed');
      },
    );
  }

  void _handleServerMessage(Map<String, dynamic> data) {
    if (data.containsKey('setupComplete')) {
      _statusController.add('Live streaming active');
      return;
    }

    final serverContent = data['serverContent'] as Map<String, dynamic>?;
    if (serverContent == null) return;

    // Handle barge-in interruption (clear speaker buffer immediately)
    if (serverContent['interrupted'] == true) {
      _interruptedController.add(null);
    }

    // Live transcription of human microphone input
    final inputTx = serverContent['inputTranscription'] as Map<String, dynamic>?;
    final userText = inputTx?['text'] as String?;
    if (userText != null && userText.trim().isNotEmpty) {
      _userTranscriptController.add(userText.trim());
    }

    // Live transcription of Gemini spoken output
    final outputTx = serverContent['outputTranscription'] as Map<String, dynamic>?;
    final modelTxText = outputTx?['text'] as String?;
    if (modelTxText != null && modelTxText.trim().isNotEmpty) {
      _modelTranscriptController.add(modelTxText.trim());
    }

    // 24kHz 16-bit PCM audio bytes from Gemini
    final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
    final parts = modelTurn?['parts'] as List<dynamic>?;
    if (parts != null) {
      for (final part in parts) {
        if (part is Map<String, dynamic>) {
          final inlineData = part['inlineData'] as Map<String, dynamic>?;
          if (inlineData != null) {
            final mimeType = inlineData['mimeType'] as String? ?? '';
            final b64 = inlineData['data'] as String?;
            if (b64 != null && mimeType.startsWith('audio/pcm')) {
              _pcmOutputController.add(base64Decode(b64));
            }
          }
        }
      }
    }
  }

  /// Stream 16kHz 16-bit little-endian mono PCM chunk to Gemini Live
  void sendAudioChunk16k(Uint8List pcmBytes) {
    if (!_isConnected || _channel == null) return;
    final payload = {
      'realtimeInput': {
        'mediaChunks': [
          {
            'mimeType': 'audio/pcm;rate=16000',
            'data': base64Encode(pcmBytes),
          }
        ],
      },
    };
    _channel!.sink.add(jsonEncode(payload));
  }

  /// Send an explicit text prompt into the active Live session (e.g. "Suggest next question")
  void sendTextPrompt(String text) {
    if (!_isConnected || _channel == null) return;
    final payload = {
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ],
          }
        ],
        'turnComplete': true,
      },
    };
    _channel!.sink.add(jsonEncode(payload));
  }

  Future<void> disconnect() async {
    _isConnected = false;
    await _wsSub?.cancel();
    _wsSub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _pcmOutputController.close();
    _userTranscriptController.close();
    _modelTranscriptController.close();
    _interruptedController.close();
    _statusController.close();
  }
}
