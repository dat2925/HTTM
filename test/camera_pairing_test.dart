import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/services/frame_source.dart';
import 'package:smart_navigation/services/ai_detection_service.dart';
import 'package:smart_navigation/services/route_service.dart';
import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute, RecordingTts;

class BorrowableCamera extends FrameSource {
  final capture = Completer<XFile>();
  int opened = 0, closed = 0;
  bool ready = false;
  @override
  bool get isReady => ready;
  @override
  Future<void> initialize() async {
    opened++;
    ready = true;
  }

  @override
  Future<void> dispose() async {
    closed++;
    ready = false;
  }

  @override
  Future<XFile> captureFrame() => capture.future;
}

class PendingDetection extends AiDetectionService {
  final reply = Completer<DetectionResult>();
  @override
  Future<bool> isHealthy() async => true;
  @override
  Future<DetectionResult> detect(XFile image) => reply.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'QR waits for capture, keeps GPS/TTS, and discards old YOLO after restore',
    () async {
      final camera = BorrowableCamera(), detection = PendingDetection();
      final route = FakeRoute(), tts = RecordingTts();
      final session = SessionController(
        frameSource: camera,
        detectionService: detection,
        routeService: route,
        ttsService: tts,
        assistantService: FakeAssistant(),
      );
      final emitted = <Object>[];
      final subscription = session.frames.listen(emitted.add);
      await session.initialize();
      expect(await session.start(), isTrue);
      final borrow = session.suspendCameraForQr();
      await Future<void>.delayed(Duration.zero);
      expect(
        camera.closed,
        0,
      ); // Cannot dispose while takePicture is still running.
      camera.capture.complete(XFile.fromData(Uint8List.fromList([1, 2, 3])));
      expect(
        await borrow,
        isTrue,
      ); // Detection reply is still pending at this point.
      expect(camera.closed, 1);
      expect(route.stopped, 0);
      expect(session.isRunning, isFalse);
      route.events.add(
        const RouteInstruction(text: 'Sau 20 mét rẽ trái', key: 'left'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(tts.spoken, contains('Sau 20 mét rẽ trái'));
      await session.resumeCameraAfterQr(restartPerception: true);
      expect(camera.opened, 2);
      expect(session.isRunning, isTrue);
      detection.reply.complete(
        const DetectionResult(imageWidth: 1, imageHeight: 1, objects: []),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        emitted,
        isEmpty,
      ); // The pre-scan frame belongs to the old perception epoch.
      await subscription.cancel();
      await session.dispose();
    },
  );
}
