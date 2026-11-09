import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

class MlKitEvent {
  final String type; // 'transcript' | 'rms' | 'status' | 'error'
  final String? text;
  final String? speaker;
  final bool isFinal;
  final String? message;
  final double? rmsdB;

  MlKitEvent({
    required this.type,
    this.text,
    this.speaker,
    this.isFinal = false,
    this.message,
    this.rmsdB,
  });

  factory MlKitEvent.fromMap(Map<dynamic, dynamic> map) {
    return MlKitEvent(
      type: map['type'] as String? ?? 'status',
      text: map['text'] as String?,
      speaker: map['speaker'] as String?,
      isFinal: map['isFinal'] as bool? ?? false,
      message: map['message'] as String?,
      rmsdB: (map['rmsdB'] as num?)?.toDouble(),
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

  Future<bool> ensureMicPermission() async {
    if (!Platform.isAndroid) return true;
    final granted = await _method.invokeMethod<bool>('ensureMicPermission');
    return granted ?? false;
  }

  Future<void> startOnDeviceStt({bool usePfdPipe = false}) async {
    if (!Platform.isAndroid) return;
    await _method.invokeMethod('startOnDeviceStt', {'usePfdPipe': usePfdPipe});
  }

  Future<void> feedPcmChunk(Uint8List pcm16kMono) async {
    if (!Platform.isAndroid) return;
    await _method.invokeMethod('feedPcmChunk', {'pcm': pcm16kMono});
  }

  Future<void> playModelPcm24k(Uint8List pcm24kMono) async {
    if (!Platform.isAndroid) return;
    await _method.invokeMethod('playModelPcm24k', {'pcm': pcm24kMono});
  }

  Future<void> clearModelAudio() async {
    if (!Platform.isAndroid) return;
    await _method.invokeMethod('clearModelAudio');
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
