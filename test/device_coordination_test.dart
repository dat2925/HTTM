import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/services/ai_detection_service.dart';
import 'package:smart_navigation/services/frame_source.dart';
import 'package:smart_navigation/services/tts_service.dart';

import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute, RecordingTts;

class ReadyCamera extends FrameSource {
  @override
  bool get isReady => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<XFile> captureFrame() async =>
      XFile.fromData(Uint8List.fromList([1, 2, 3]));
  @override
  Future<void> dispose() async {}
}

class SlowDetector extends AiDetectionService {
  final replies = <Completer<DetectionResult>>[];
  @override
  Future<bool> isHealthy() async => true;
  @override
  Future<DetectionResult> detect(XFile image) {
    final reply = Completer<DetectionResult>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'one YOLO request at a time; pause discards old detection and resume restarts',
    () async {
      final detector = SlowDetector();
      final session = SessionController(
        frameSource: ReadyCamera(),
        detectionService: detector,
        routeService: FakeRoute(),
        ttsService: RecordingTts(),
        assistantService: FakeAssistant(),
      );
      final frames = <Object>[];
      final subscription = session.frames.listen(frames.add);
      await session.initialize();
      expect(await session.start(), isTrue);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 1900));
      expect(detector.replies, hasLength(1));
      session.pauseNavigation();
      detector.replies.first.complete(
        const DetectionResult(imageWidth: 1, imageHeight: 1, objects: []),
      );
      await Future<void>.delayed(Duration.zero);
      expect(frames, isEmpty);
      expect(session.isRunning, isFalse);
      await session.resumeNavigation();
      expect(await session.start(), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(detector.replies, hasLength(2));
      detector.replies.last.complete(
        const DetectionResult(imageWidth: 1, imageHeight: 1, objects: []),
      );
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(1));
      await subscription.cancel();
      await session.dispose();
    },
  );

  test(
    'obstacle TTS interrupts AI and silence clears priority for STT',
    () async {
      const channel = MethodChannel('flutter_tts');
      final spoken = <String>[];
      var stops = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'stop') stops++;
        if (call.method == 'speak') {
          spoken.add(call.arguments as String);
        }
        return 1;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final tts = TtsService();
      await tts.initialize();
      expect(await tts.speak('Trợ lý đang giải thích', priority: 0), isTrue);
      expect(await tts.speak('Có vật cản phía trước', priority: 3), isTrue);
      expect(await tts.speak('Trợ lý tiếp tục', priority: 0), isFalse);
      expect(spoken, ['Trợ lý đang giải thích', 'Có vật cản phía trước']);
      expect(stops, 2);
      await tts.silence();
      expect(stops, 3);
      expect(await tts.speak('Đã nghe xong', priority: 0), isTrue);
      await tts.dispose();
    },
  );
}
