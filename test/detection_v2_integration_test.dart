// In-process integration of camera/session/tracker/risk/TTS/QR and route.
// This uses fake hardware, not an Android camera/inference performance test.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:smart_navigation/config/ai_config.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/models/perception_frame.dart';

import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute;
import 'support/device_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  DetectionResult scene(String name, DangerLevel danger) => DetectionResult(
    imageWidth: 100,
    imageHeight: 100,
    model: 'fixture-n',
    objects: [
      DetectedObject(
        className: name,
        confidence: .9,
        position: 'center',
        danger: danger,
        areaRatio: .2,
        x1: 20,
        y1: 10,
        x2: 80,
        y2: 90,
      ),
    ],
  );

  test(
    'noise confirmation, urgent first frame, QR reset and GPS continuity',
    () {
      fakeAsync((async) {
        final camera = FakeCamera(),
            detector = FakeDetector(),
            tts = RecordingTts(),
            route = FakeRoute();
        detector.result = scene('pole', DangerLevel.medium);
        final session = SessionController(
          voiceService: FakeVoice(),
          frameSource: camera,
          detectionService: detector,
          ttsService: tts,
          routeService: route,
          assistantService: FakeAssistant(),
          now: async.getClock(DateTime.utc(2026, 11, 18)).now,
        );
        final frames = <PerceptionFrame>[];
        final subscription = session.frames.listen(frames.add);
        session.initialize();
        async.flushMicrotasks();
        session.start();
        async.flushMicrotasks();
        Iterable<String> warnings() =>
            tts.spoken.where((s) => s.$2 == 3).map((s) => s.$1);
        expect(frames.single.objects.single.isStable, isFalse);
        expect(warnings(), isEmpty);
        detector.result = emptyDetection;
        async.elapse(AiConfig.captureInterval);
        expect(warnings(), isEmpty);
        detector.result = scene('car', DangerLevel.high);
        async.elapse(AiConfig.captureInterval);
        expect(warnings(), hasLength(1));
        expect(frames.last.objects.single.isStable, isFalse);
        final oldId = frames.last.objects.single.trackId;
        async.elapse(AiConfig.captureInterval * 2);
        expect(warnings(), hasLength(1));
        final routeStarts = route.started;
        session.suspendCameraForQr();
        async.flushMicrotasks();
        expect(camera.ready, isFalse);
        expect(route.stopped, 0);
        session.resumeCameraAfterQr(restartPerception: true);
        async.flushMicrotasks();
        expect(camera.ready, isTrue);
        expect(frames.last.objects.single.trackId, isNot(oldId));
        expect(route.started, routeStarts);
        subscription.cancel();
        session.dispose();
        async.flushMicrotasks();
      });
    },
  );
}
