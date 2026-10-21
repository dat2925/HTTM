import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/services/ai_detection_service.dart';
import 'package:smart_navigation/services/frame_source.dart';
import 'package:smart_navigation/services/tts_service.dart';
import 'package:smart_navigation/services/voice_service.dart';

const emptyDetection = DetectionResult(
  imageWidth: 100,
  imageHeight: 100,
  objects: [],
);
const dangerDetection = DetectionResult(
  imageWidth: 100,
  imageHeight: 100,
  objects: [
    DetectedObject(
      className: 'person',
      confidence: 0.9,
      position: 'center',
      danger: DangerLevel.high,
      areaRatio: 0.4,
      x1: 20,
      y1: 0,
      x2: 80,
      y2: 90,
    ),
  ],
);

class FakeCamera extends FrameSource {
  bool ready = false, failOpen = false, failCapture = false;
  int opened = 0, closed = 0, captures = 0;
  Completer<XFile>? captureGate;
  Completer<void>? openGate;
  @override
  bool get isReady => ready;
  @override
  Future<void> initialize() async {
    opened++;
    await openGate?.future;
    if (failOpen) throw CameraException('permission', 'No camera');
    ready = true;
  }

  @override
  Future<XFile> captureFrame() async {
    captures++;
    if (failCapture) throw CameraException('capture', 'Capture failed');
    return captureGate?.future ?? XFile.fromData(Uint8List.fromList([1, 2, 3]));
  }

  @override
  Future<void> dispose() async {
    closed++;
    ready = false;
  }
}

class FakeDetector extends AiDetectionService {
  bool healthy = true, deferred = false, fail = false;
  Completer<bool>? healthGate;
  int requests = 0;
  DetectionResult result = emptyDetection;
  final pending = <Completer<DetectionResult>>[];
  @override
  Future<bool> isHealthy() async => healthGate?.future ?? healthy;
  @override
  Future<DetectionResult> detect(XFile image) async {
    requests++;
    if (fail) throw const AiDetectionException('Server nhận diện đang lỗi.');
    if (!deferred) return result;
    final reply = Completer<DetectionResult>();
    pending.add(reply);
    return reply.future;
  }
}

class RecordingTts extends TtsService {
  final spoken = <(String, int)>[];
  int silences = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> speak(String text, {int priority = 2}) async {
    spoken.add((text, priority));
    return true;
  }

  @override
  Future<void> silence() async {
    silences++;
  }

  @override
  Future<void> dispose() async {}
}

class FakeVoice extends VoiceService {
  String? text;
  bool fail = false;
  int starts = 0, stops = 0, cancels = 0;
  Completer<void>? startGate;
  Completer<String?>? stopGate;
  @override
  Future<void> startListening({void Function(String)? onResult}) async {
    starts++;
    if (fail) throw const VoiceException('No microphone');
    await startGate?.future;
  }

  @override
  Future<String?> stopListening() async {
    stops++;
    return stopGate?.future ?? text;
  }

  Future<void> cancelListening() async {
    cancels++;
  }

  @override
  void dispose() {}
}

Future<void> flushDeviceEvents() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
