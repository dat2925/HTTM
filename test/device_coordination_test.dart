import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/services/route_service.dart';
import 'package:smart_navigation/models/assistant_state.dart';
import 'package:smart_navigation/services/assistant_service.dart';

import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute;
import 'support/device_fakes.dart';

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
}
