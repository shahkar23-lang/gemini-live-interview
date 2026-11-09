import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Supports continuous 60-minute Gemini Live sessions using:
/// 1. `contextWindowCompression.slidingWindow` (removes the 15-minute audio token ceiling)
/// 2. `sessionResumption` (`newHandle` caching + automatic transparent reconnection on `goAway` or socket rotation)
class GeminiLiveService {
  static const Duration maxSessionDuration = Duration(minutes: 60);

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  bool _isConnected = false;
  bool _keepSessionAlive = false;

  String? _apiKey;
  String _model = 'models/gemini-2.5-flash';
  String _voiceName = 'Aoede';
  bool _aiCoInterviewerMode = true;
  String? _resumptionHandle;
  DateTime? _sessionStartedAt;
  int _reconnectionCount = 0;

  bool get isConnected => _isConnected;
  int get reconnectionCount => _reconnectionCount;

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
    _apiKey = apiKey;
    _model = model;
    _voiceName = voiceName;
    _aiCoInterviewerMode = aiCoInterviewerMode;
    _keepSessionAlive = true;
    _resumptionHandle = null;
    _reconnectionCount = 0;
    _sessionStartedAt = DateTime.now();

    await _openWebSocket(isResume: false);
  }

  Future<void> _openWebSocket({required bool isResume}) async {
    await _closeSocketOnly();
    if (!_keepSessionAlive || _apiKey == null) return;

    final uri = Uri.parse(
      'wss://generativelanguage.googleapis.com/ws/'
      'google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent'
      '?key=$_apiKey',
    );

    _statusController.add(
      isResume
          ? 'Resuming 60-min Live session (#$_reconnectionCount)...'
          : 'Connecting to Gemini Live (60-min sliding-window mode)...',
    );

    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;
      _isConnected = true;
    } catch (e) {
      _isConnected = false;
      _statusController.add('Gemini Live connection error ($e). Retrying...');
      _scheduleReconnectIfWithin60Min();
      return;
    }

    final systemPrompt = _aiCoInterviewerMode
        ? 'You are an expert technical co-interviewer in a 60-minute live interview. '
          'Keep spoken replies concise (1-2 sentences) and only chime in when addressed '
          'or asked for a follow-up question.'
        : 'Listen quietly to the 60-minute interview conversation without interrupting unless explicitly asked.';

    // BidiGenerateContentSetup with contextWindowCompression (slidingWindow) + sessionResumption
    // so the session runs continuously up to 60 minutes without hitting the 15-min ceiling.
    final setupPayload = {
      'setup': {
        'model': _model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': _voiceName},
            },
          },
        },
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt}
          ],
        },
        'contextWindowCompression': {
          'slidingWindow': {},
        },
        'sessionResumption': {
          if (_resumptionHandle != null) 'handle': _resumptionHandle,
        },
        'inputAudioTranscription': {},
        'outputAudioTranscription': {},
      },
    };

    _channel!.sink.add(jsonEncode(setupPayload));

    _wsSub = _channel!.stream.listen(
      (rawEvent) {
        final jsonStr = rawEvent is Uint8List ? utf8.decode(rawEvent) : rawEvent.toString();
        final Map<String, dynamic> data = jsonDecode(jsonStr) as Map<String, dynamic>;
        _handleServerMessage(data);
      },
      onError: (e) {
        _isConnected = false;
        _statusController.add('Live stream interrupted ($e) — auto-resuming...');
        _scheduleReconnectIfWithin60Min();
      },
      onDone: () {
        _isConnected = false;
        if (_keepSessionAlive) {
          _scheduleReconnectIfWithin60Min();
        } else {
          _statusController.add('Gemini Live session closed');
        }
      },
    );
  }

  void _scheduleReconnectIfWithin60Min() {
    if (!_keepSessionAlive || _sessionStartedAt == null) return;
    final elapsed = DateTime.now().difference(_sessionStartedAt!);
    if (elapsed >= maxSessionDuration) {
      _keepSessionAlive = false;
      _statusController.add('60-minute session limit reached.');
      return;
    }

    _reconnectionCount++;
    Future.delayed(const Duration(milliseconds: 450), () {
      if (_keepSessionAlive) {
        _openWebSocket(isResume: true);
      }
    });
  }

  void _handleServerMessage(Map<String, dynamic> data) {
    if (data.containsKey('setupComplete')) {
      _statusController.add(
        _reconnectionCount == 0
            ? 'Live streaming active (60-min mode)'
            : 'Live streaming active (resumed #$_reconnectionCount)',
      );
      return;
    }

    // Cache cryptographic session resumption handle for seamless 60-minute continuity
    final resumptionUpdate = data['sessionResumptionUpdate'] as Map<String, dynamic>?;
    if (resumptionUpdate != null) {
      final newHandle = resumptionUpdate['newHandle'] as String?;
      final resumable = resumptionUpdate['resumable'] as bool? ?? true;
      if (resumable && newHandle != null && newHandle.isNotEmpty) {
        _resumptionHandle = newHandle;
      }
    }

    // Proactively rotate connection if server sends goAway before transport timeout (~10-15m)
    if (data.containsKey('goAway') && _keepSessionAlive) {
      _statusController.add('Rotating WebSocket transport for 60-min continuity...');
      _scheduleReconnectIfWithin60Min();
      return;
    }

    final serverContent = data['serverContent'] as Map<String, dynamic>?;
    if (serverContent == null) return;

    if (serverContent['interrupted'] == true) {
      _interruptedController.add(null);
    }

    final inputTx = serverContent['inputTranscription'] as Map<String, dynamic>?;
    final userText = inputTx?['text'] as String?;
    if (userText != null && userText.trim().isNotEmpty) {
      _userTranscriptController.add(userText.trim());
    }

    final outputTx = serverContent['outputTranscription'] as Map<String, dynamic>?;
    final modelTxText = outputTx?['text'] as String?;
    if (modelTxText != null && modelTxText.trim().isNotEmpty) {
      _modelTranscriptController.add(modelTxText.trim());
    }

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

  Future<void> _closeSocketOnly() async {
    _isConnected = false;
    await _wsSub?.cancel();
    _wsSub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> disconnect() async {
    _keepSessionAlive = false;
    await _closeSocketOnly();
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
