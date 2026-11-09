import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

class MlKitEvent {
  final String type; // 'transcript' | 'status' | 'error'
  final String? text;
  final String? speaker;
  final bool isFinal;
  final String? message;

  MlKitEvent({
    required this.type,
    this.text,
    this.speaker,
    this.isFinal = false,
    this.message,
  });

  factory MlKitEvent.fromMap(Map<dynamic, dynamic> map) {
    return MlKitEvent(
      type: map['type'] as String? ?? 'status',
      text: map['text'] as String?,
      speaker: map['speaker'] as String?,
      isFinal: map['isFinal'] as bool? ?? false,
      message: map['message'] as String?,
    );
  }
}

class MlKitNativeBridge {
  static const MethodChannel _method = MethodChannel('com.interview.ai/mlkit');
  static const EventChannel _events = EventChannel('com.interview.ai/mlkit_stream');

  Stream<MlKitEvent> get events {
    if (!Platform.isAndroid) return const Stream.empty();
    return _events
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => MlKitEvent.fromMap(e as Map));
  }

  Future<void> startOnDeviceStt() async {
    if (!Platform.isAndroid) return;
    await _method.invokeMethod('startOnDeviceStt');
  }

  Future<void> feedPcmChunk(Uint8List pcm16kMono) async {
    if (!Platform.isAndroid) return;
    await _method.invokeMethod('feedPcmChunk', {'pcm': pcm16kMono});
  }

  Future<void> stopOnDeviceStt() async {
    if (!Platform.isAndroid) return;
    await _method.invokeMethod('stopOnDeviceStt');
  }

  Future<String> summarizeOnDevice(String transcript) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('ML Kit GenAI Summarization is Android-only.');
    }
    final res = await _method.invokeMethod<String>(
      'summarizeOnDevice',
      {'transcript': transcript},
    );
    return res ?? '';
  }
}
