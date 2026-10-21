import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/services/route_service.dart';

import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute;
import 'support/device_fakes.dart';

class RecoverableTts extends RecordingTts {
  int attempts = 0;
  bool fail = true, failSilence = false;
  Completer<void>? startup;
  @override
  Future<void> initialize() async {
    attempts++;
    await startup?.future;
    if (fail) throw StateError('native TTS startup failed');
  }

  @override
  Future<void> silence() async {
    if (failSilence) throw StateError('native TTS stop failed');
    await super.silence();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecoverableTts tts;
  late FakeCamera camera;
  late FakeRoute route;
  late FakeVoice voice;
  late SessionController session;
  setUp(() {
    tts = RecoverableTts();
    camera = FakeCamera();
    route = FakeRoute();
    voice = FakeVoice();
    session = SessionController(
      ttsService: tts,
      frameSource: camera,
      routeService: route,
      voiceService: voice,
      assistantService: FakeAssistant(),
    );
  });
  tearDown(() => session.dispose());

  test(
    'failed TTS startup leaves GPS camera and local STT available',
    () async {
      await session.initialize();
      expect(session.ttsError, isNotNull);
      expect(route.started, 1);
      expect(camera.ready, isTrue);
      voice.text = 'cập nhật tuyến';
      await session.onTalkStart();
      await session.onTalkEnd();
      expect(route.refreshes, 1);
    },
  );

  test(
    'TTS can retry without duplicating navigation subscriptions or camera',
    () async {
      await session.initialize();
      tts.fail = false;
      await session.initialize();
      expect(tts.attempts, 2);
      expect(session.ttsError, isNull);
      expect(route.started, 1);
      expect(camera.opened, 1);
      route.events.add(const RouteInstruction(text: 'Rẽ trái', key: 'left'));
      await flushDeviceEvents();
      expect(tts.spoken, [('Rẽ trái', 1)]);
    },
  );

  test('resume retries failed TTS alongside GPS and camera', () async {
    await session.initialize();
    await session.pauseNavigation();
    tts.fail = false;
    await session.resumeNavigation();
    expect(tts.attempts, 2);
    expect(session.ttsError, isNull);
    expect(camera.ready, isTrue);
    expect(route.started, 2);
  });

  test(
    'native silence failure does not block STT or lifecycle cleanup',
    () async {
      tts.fail = false;
      tts.failSilence = true;
      await session.initialize();
      await session.onTalkStart();
      expect(session.isListening, isTrue);
      await session.pauseNavigation();
      expect(voice.cancels, 1);
      expect(camera.ready, isFalse);
    },
  );

  test('concurrent initialize shares one TTS attempt', () async {
    tts.fail = false;
    tts.startup = Completer<void>();
    final attempts = [
      session.initialize(),
      session.initialize(),
      session.initialize(),
    ];
    await flushDeviceEvents();
    expect(tts.attempts, 1);
    expect(route.started, 1);
    tts.startup!.complete();
    await Future.wait(attempts);
    expect(camera.opened, 1);
  });

  test('pause discards route speech waiting for TTS initialization', () async {
    tts.fail = false;
    tts.startup = Completer<void>();
    final starting = session.initialize();
    await flushDeviceEvents();
    route.events.add(
      const RouteInstruction(text: 'old instruction', key: 'old'),
    );
    final pausing = session.pauseNavigation();
    tts.startup!.complete();
    await Future.wait([starting, pausing]);
    expect(tts.spoken, isEmpty);
  });

  testWidgets('hung TTS startup is bounded while GPS and camera start', (
    tester,
  ) async {
    tts.startup = Completer<void>();
    final starting = session.initialize();
    await tester.pump();
    expect(route.started, 1);
    expect(camera.ready, isTrue);
    await tester.pump(const Duration(seconds: 6));
    await starting;
    expect(session.ttsError, isNotNull);
    tts.startup!.complete();
    await tester.pump();
    await tester.runAsync(session.dispose);
  });
}
