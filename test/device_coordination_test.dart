import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/config/ai_config.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/services/route_service.dart';
import 'package:smart_navigation/models/assistant_state.dart';
import 'package:smart_navigation/services/assistant_service.dart';
import 'package:smart_navigation/services/detection_backend.dart';
import 'package:smart_navigation/services/on_device_detection_service.dart';

import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute;
import 'support/device_fakes.dart';
import 'on_device_detection_test.dart' show FakeYoloEngine;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCamera camera;
  late FakeDetector detector;
  late RecordingTts tts;
  late FakeRoute route;
  late SessionController session;

  setUp(() async {
    camera = FakeCamera();
    detector = FakeDetector();
    tts = RecordingTts();
    route = FakeRoute();
    session = SessionController(
      frameSource: camera,
      detectionService: detector,
      ttsService: tts,
      routeService: route,
      assistantService: FakeAssistant(),
    );
    await session.initialize();
  });
  tearDown(() => session.dispose());

  test('device backend uses 500 ms capture interval after each start', () {
    fakeAsync((async) {
      final engine = FakeYoloEngine();
      final deviceSession = SessionController(
        frameSource: FakeCamera(),
        detectionService: HybridDetectionService(
          server: FakeDetector()..healthy = false,
          device: OnDeviceDetector(engine: engine),
        ),
        ttsService: RecordingTts(),
        routeService: FakeRoute(),
        assistantService: FakeAssistant(),
      );
      deviceSession.initialize();
      async.flushMicrotasks();
      for (var start = 0; start < 2; start++) {
        deviceSession.start();
        async.flushMicrotasks();
        expect(deviceSession.detectionBackend, 'device');
        final before = engine.predictions;
        async.elapse(
          AiConfig.deviceCaptureInterval - const Duration(milliseconds: 1),
        );
        expect(engine.predictions, before);
        async.elapse(const Duration(milliseconds: 1));
        expect(engine.predictions, before + 1);
        deviceSession.stop();
      }
      deviceSession.dispose();
      async.flushMicrotasks();
    });
  });

  test(
    'device-only prepare failure never speaks server-unreachable notice',
    () async {
      final deviceTts = RecordingTts();
      final deviceSession = SessionController(
        frameSource: FakeCamera(),
        detectionService: HybridDetectionService(
          server: FakeDetector(),
          device: OnDeviceDetector(engine: FakeYoloEngine()..failLoad = true),
          mode: DetectionMode.device,
        ),
        ttsService: deviceTts,
        routeService: FakeRoute(),
        assistantService: FakeAssistant(),
      );
      await deviceSession.initialize();
      expect(await deviceSession.start(), isFalse);
      expect(deviceTts.spoken, isNotEmpty);
      expect(
        deviceTts.spoken.every((speech) => !speech.$1.contains('AI Server')),
        isTrue,
      );
      await deviceSession.dispose();
    },
  );

  test('stop during health check cannot start perception', () async {
    detector.healthGate = Completer<bool>();
    final starting = session.start();
    session.stop();
    detector.healthGate!.complete(true);
    expect(await starting, isFalse);
    expect(camera.captures, 0);
  });

  test('only one request runs while inference is pending', () async {
    detector.deferred = true;
    await session.start();
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(detector.requests, 1);
    expect(camera.captures, 1);
    session.stop();
    detector.pending.single.complete(emptyDetection);
    await flushDeviceEvents();
  });

  test(
    'pause waits for capture, releases camera, and resumes GPS and perception',
    () async {
      camera.captureGate = Completer();
      detector.deferred = true;
      final frames = <Object>[];
      final subscription = session.frames.listen(frames.add);
      await session.start();
      await flushDeviceEvents();
      final pausing = session.pauseNavigation();
      await flushDeviceEvents();
      expect(camera.closed, 0);
      camera.captureGate!.complete(await FakeCamera().captureFrame());
      await pausing;
      expect(camera.ready, isFalse);
      expect(route.stopped, 1);
      await flushDeviceEvents();
      detector.pending.single.complete(dangerDetection);
      await flushDeviceEvents();
      expect(frames, isEmpty);
      expect(tts.spoken, isEmpty);
      await session.resumeNavigation();
      camera.captureGate = null;
      expect(camera.opened, 2);
      expect(route.started, 2);
      expect(await session.start(), isTrue);
      await flushDeviceEvents();
      detector.pending.last.complete(emptyDetection);
      await flushDeviceEvents();
      expect(frames, hasLength(1));
      await subscription.cancel();
    },
  );

  test(
    'disposal rejects a late detection without publishing to closed streams',
    () async {
      detector.deferred = true;
      await session.start();
      await flushDeviceEvents();
      await session.dispose();
      detector.pending.single.complete(dangerDetection);
      await flushDeviceEvents();
      expect(session.isRunning, isFalse);
      expect(tts.spoken, isEmpty);
    },
  );

  test(
    'backend failure leaves GPS guidance available and allows retry',
    () async {
      detector.fail = true;
      await session.start();
      await flushDeviceEvents();
      expect(session.cameraError, isNotNull);
      route.events.add(const RouteInstruction(text: 'Rẽ trái', key: 'left'));
      await flushDeviceEvents();
      expect(tts.spoken, contains(('Rẽ trái', 1)));
      expect(route.stopped, 0);
      detector.fail = false;
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(detector.requests, greaterThan(1));
      expect(session.cameraError, isNull);
    },
  );

  test('danger warning preempts AI and repeated warning cools down', () async {
    final haptics = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await session.handleUtterance('Giải thích ngữ cảnh');
    expect(tts.spoken.last.$2, 0);
    detector.result = dangerDetection;
    await session.start();
    await flushDeviceEvents();
    expect(tts.spoken.last.$2, 3);
    expect(haptics, ['HapticFeedbackType.heavyImpact']);
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    expect(tts.spoken.where((s) => s.$2 == 3), hasLength(1));
  });

  test(
    'camera and navigation continue while AI stalls then times out',
    () async {
      final ai = FakeAssistant()..pending = Completer<AssistantReply>();
      final independentCamera = FakeCamera();
      final independentDetector = FakeDetector()..result = dangerDetection;
      final independentRoute = FakeRoute();
      final independentTts = RecordingTts();
      final independent = SessionController(
        frameSource: independentCamera,
        detectionService: independentDetector,
        routeService: independentRoute,
        ttsService: independentTts,
        assistantService: ai,
      );
      addTearDown(independent.dispose);
      await independent.initialize();
      final asking = independent.handleUtterance('Có xe chắn, tôi nên làm gì?');
      await independent.start();
      await flushDeviceEvents();
      expect(ai.pending!.isCompleted, false);
      expect(independentTts.spoken.any((s) => s.$2 == 3), true);
      expect(independentRoute.started, 1);
      expect(independentCamera.captures, 1);
      ai.pending!.completeError(
        const AssistantException('Timeout mock', code: 'timeout'),
      );
      await asking;
      independentDetector.result = emptyDetection;
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(independentDetector.requests, greaterThan(1));
      expect(independentRoute.stopped, 0);
    },
  );

  test(
    'unhealthy detector speaks once, retries every 10s, and announces recovery',
    () => fakeAsync((async) {
      final fCamera = FakeCamera(),
          fDetector = FakeDetector()..healthy = false,
          fTts = RecordingTts(),
          fRoute = FakeRoute();
      final fSession = SessionController(
        frameSource: fCamera,
        detectionService: fDetector,
        ttsService: fTts,
        routeService: fRoute,
        assistantService: FakeAssistant(),
      );
      fSession.initialize();
      async.flushMicrotasks();

      bool? started;
      fSession.start().then((v) => started = v);
      async.flushMicrotasks();
      expect(started, isFalse);
      expect(
        fTts.spoken.where(
          (s) =>
              s.$1 ==
              'Cảnh báo vật cản đang tắt vì không kết nối được AI Server. Đang thử lại.',
        ),
        hasLength(1),
      );
      expect(fSession.isRunning, isFalse);

      // First retry at 10s still unhealthy: must not repeat the offline speech.
      async.elapse(AiConfig.detectorRetryInterval);
      expect(
        fTts.spoken.where(
          (s) =>
              s.$1 ==
              'Cảnh báo vật cản đang tắt vì không kết nối được AI Server. Đang thử lại.',
        ),
        hasLength(1),
      );
      expect(fSession.isRunning, isFalse);

      // Next retry at 20s succeeds: starts perception and announces recovery.
      fDetector.healthy = true;
      async.elapse(AiConfig.detectorRetryInterval);
      expect(fSession.isRunning, isTrue);
      expect(
        fTts.spoken.any((s) => s.$1 == 'Cảnh báo vật cản đã hoạt động lại.'),
        isTrue,
      );
      fSession.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'detector retry timer is canceled on pause, QR borrow, stop, and does not stack',
    () => fakeAsync((async) {
      final fCamera = FakeCamera(),
          fDetector = FakeDetector()..healthy = false,
          fTts = RecordingTts(),
          fRoute = FakeRoute();
      final fSession = SessionController(
        frameSource: fCamera,
        detectionService: fDetector,
        ttsService: fTts,
        routeService: fRoute,
        assistantService: FakeAssistant(),
      );
      fSession.initialize();
      async.flushMicrotasks();

      fSession.start();
      async.flushMicrotasks();
      fSession.start();
      async.flushMicrotasks();
      fDetector.healthGate = Completer<bool>();
      async.elapse(AiConfig.detectorRetryInterval);
      // Only one timer should have fired after 10s despite two start() calls.
      expect(fDetector.healthGate!.isCompleted, isFalse);
      fDetector.healthGate!.complete(false);
      fDetector.healthGate = null;
      async.flushMicrotasks();

      // Pause cancels retry timer.
      fSession.pauseNavigation();
      async.flushMicrotasks();
      fDetector.healthy = true;
      async.elapse(AiConfig.detectorRetryInterval * 2);
      expect(fSession.isRunning, isFalse);

      // Resume and fail health again, then borrow camera for QR.
      fSession.resumeNavigation();
      async.flushMicrotasks();
      fDetector.healthy = false;
      fSession.start();
      async.flushMicrotasks();
      fSession.suspendCameraForQr();
      async.flushMicrotasks();
      fDetector.healthy = true;
      async.elapse(AiConfig.detectorRetryInterval * 2);
      expect(fSession.isRunning, isFalse);
      fSession.resumeCameraAfterQr(restartPerception: false);
      async.flushMicrotasks();

      // Fail health again, then stop() (epoch change) cancels retry.
      fDetector.healthy = false;
      fSession.start();
      async.flushMicrotasks();
      fSession.stop();
      fDetector.healthy = true;
      final healthChecks = fDetector.requests;
      async.elapse(AiConfig.detectorRetryInterval * 2);
      expect(fSession.isRunning, isFalse);
      expect(fDetector.requests, healthChecks);
      fSession.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'detect timeout triggers missing obstacle data warning with cooldown',
    () => fakeAsync((async) {
      final fCamera = FakeCamera(),
          fDetector = FakeDetector()..deferred = true,
          fTts = RecordingTts(),
          fRoute = FakeRoute();
      final fSession = SessionController(
        frameSource: fCamera,
        detectionService: fDetector,
        ttsService: fTts,
        routeService: fRoute,
        assistantService: FakeAssistant(),
      );
      fSession.initialize();
      async.flushMicrotasks();

      fSession.start();
      async.flushMicrotasks();
      expect(fDetector.requests, 1);

      async.elapse(AiConfig.detectTimeout);
      expect(
        fTts.spoken.where(
          (s) =>
              s.$1 ==
              'Chưa có nhận diện camera mới. Cảnh báo vật cản đang thiếu dữ liệu.',
        ),
        hasLength(1),
      );
      expect(fSession.cameraError, contains('quá thời gian'));

      // Next cycle also times out within 30s cooldown: warning is not repeated.
      async.elapse(AiConfig.captureInterval + AiConfig.detectTimeout);
      expect(
        fTts.spoken.where(
          (s) =>
              s.$1 ==
              'Chưa có nhận diện camera mới. Cảnh báo vật cản đang thiếu dữ liệu.',
        ),
        hasLength(1),
      );
      fSession.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'obstacle detection restarts after resume when the camera reopens slowly',
    () => fakeAsync((async) {
      final camera = FakeCamera(), detector = FakeDetector();
      final session = SessionController(
        frameSource: camera,
        detectionService: detector,
        ttsService: RecordingTts(),
        routeService: FakeRoute(),
        assistantService: FakeAssistant(),
      );
      session.initialize();
      async.flushMicrotasks();
      session.start();
      async.flushMicrotasks();
      expect(session.isRunning, isTrue);

      session.pauseNavigation();
      async.flushMicrotasks();
      expect(session.isRunning, isFalse);

      // Same sequence as HomeScreen._resume(): resume, then start.
      camera.openGate = Completer<void>();
      var started = false;
      session.resumeNavigation().then((_) async {
        started = await session.start();
      });
      async.elapse(const Duration(milliseconds: 300));
      expect(started, isFalse);
      camera.openGate!.complete();
      async.flushMicrotasks();
      expect(started, isTrue);
      expect(session.isRunning, isTrue);
      session.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'hung camera capture and init time out and resumeNavigation restarts GPS immediately',
    () => fakeAsync((async) {
      final fCamera = FakeCamera(),
          fDetector = FakeDetector(),
          fTts = RecordingTts(),
          fRoute = FakeRoute();
      final fSession = SessionController(
        frameSource: fCamera,
        detectionService: fDetector,
        ttsService: fTts,
        routeService: fRoute,
        assistantService: FakeAssistant(),
      );
      fSession.initialize();
      async.flushMicrotasks();

      // 1. Capture timeout (5s) triggers perception failure handling.
      fCamera.captureGate = Completer();
      fSession.start();
      async.flushMicrotasks();
      async.elapse(AiConfig.captureTimeout);
      expect(fSession.cameraError, 'Lỗi chụp ảnh từ camera.');
      expect(
        fTts.spoken.any(
          (s) =>
              s.$1 ==
              'Chưa có nhận diện camera mới. Cảnh báo vật cản đang thiếu dữ liệu.',
        ),
        isTrue,
      );

      // 2. Hung camera during pause does not block GPS restart on resumeNavigation.
      async.elapse(AiConfig.captureInterval);
      var pauseDone = false;
      fSession.pauseNavigation().then((_) => pauseDone = true);
      async.flushMicrotasks();
      expect(fRoute.stopped, 1);
      expect(pauseDone, isFalse);

      var resumeDone = false;
      fSession.resumeNavigation().then((_) => resumeDone = true);
      async.flushMicrotasks();
      expect(fRoute.started, 2); // GPS restarted before camera pause finished!
      expect(resumeDone, isFalse); // ...but resume still waits for the camera.

      // Let the hung capture time out so pause & reopen finish.
      fCamera.captureGate = null;
      async.elapse(AiConfig.captureTimeout);
      expect(pauseDone, isTrue);
      expect(fCamera.ready, isTrue);
      expect(resumeDone, isTrue);

      // 3. Camera init timeout (10s) sets cameraError without blocking GPS.
      fSession.pauseNavigation();
      async.flushMicrotasks();
      fCamera.openGate = Completer<void>();
      fSession.resumeNavigation();
      async.flushMicrotasks();
      expect(fRoute.started, 3);
      async.elapse(AiConfig.cameraInitTimeout);
      expect(
        fSession.cameraError,
        'Camera chưa sẵn sàng. Bản đồ và GPS vẫn hoạt động.',
      );
      fSession.dispose();
      async.flushMicrotasks();
    }),
  );
}
