import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/models/session_state.dart';
import 'package:smart_navigation/services/voice_command_router.dart';

import 'support/device_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeCamera camera;
  late FakeDetector detector;
  late FakeVoice voice;
  late RecordingTts tts;
  late SessionController session;
  late List<VoiceCommand> commands;
  late List<DangerLevel> haptics;

  setUp(() {
    camera = FakeCamera();
    detector = FakeDetector();
    voice = FakeVoice();
    tts = RecordingTts();
    commands = [];
    haptics = [];
    session = SessionController(
      frameSource: camera,
      detectionService: detector,
      voiceService: voice,
      ttsService: tts,
      captureInterval: const Duration(milliseconds: 30),
      onVoiceCommand: (command, _) => commands.add(command),
      onHaptic: (danger) async {
        haptics.add(danger);
      },
    );
  });
  tearDown(() => session.dispose());

  test('only one request while inference is pending', () async {
    detector.deferred = true;
    await session.start();
    await Future<void>.delayed(const Duration(milliseconds: 110));
    expect(detector.requests, 1);
    expect(camera.captures, 1);
    detector.pending.single.complete(emptyDetection);
    await flushDeviceEvents();
    session.stop();
  });

  test(
    'pause discards an old detection; resume publishes a fresh frame',
    () async {
      detector.deferred = true;
      final frames = <Object>[];
      final sub = session.frames.listen(frames.add);
      await session.start();
      await flushDeviceEvents();
      await session.pause();
      detector.pending.first.complete(dangerDetection);
      await flushDeviceEvents();
      expect(frames, isEmpty);
      expect(tts.spoken, isEmpty);
      expect(haptics, isEmpty);
      expect(camera.ready, isFalse);
      await session.resume();
      await flushDeviceEvents();
      expect(detector.requests, 2);
      detector.pending.last.complete(emptyDetection);
      await flushDeviceEvents();
      expect(frames, hasLength(1));
      expect(session.isRunning, isTrue);
      await sub.cancel();
    },
  );

  test(
    'camera initialization failure leaves speech integration usable',
    () async {
      camera.failOpen = true;
      expect(await session.start(), isFalse);
      expect(session.cameraError, isNotNull);
      expect(await session.speakGuidance('Rẽ trái'), isTrue);
      expect(tts.spoken.single, ('Rẽ trái', 1));
    },
  );

  test('capture failure is reported and a later capture can recover', () async {
    camera.failCapture = true;
    await session.start();
    await flushDeviceEvents();
    expect(session.cameraError, isNotNull);
    expect(detector.requests, 0);
    camera.failCapture = false;
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(detector.requests, greaterThan(0));
    expect(session.cameraError, isNull);
  });

  test('inference failure releases the request guard for retry', () async {
    detector.fail = true;
    await session.start();
    await flushDeviceEvents();
    expect(session.cameraError, contains('Server'));
    detector.fail = false;
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(detector.requests, greaterThan(1));
    expect(session.cameraError, isNull);
  });

  test(
    'stop during initial camera opening cancels the pending start',
    () async {
      camera.openGate = Completer<void>();
      final pending = session.start();
      await flushDeviceEvents();
      expect(camera.opened, 1);
      session.stop();
      camera.openGate!.complete();
      expect(await pending, isFalse);
      expect(session.isRunning, isFalse);
      expect(detector.requests, 0);
      expect(await session.start(), isTrue);
    },
  );

  test('stop during camera recovery cancels the pending start', () async {
    camera.failOpen = true;
    await session.initialize();
    camera.failOpen = false;
    camera.openGate = Completer<void>();
    final pending = session.start();
    await flushDeviceEvents();
    expect(camera.opened, 2);
    session.stop();
    camera.openGate!.complete();
    expect(await pending, isFalse);
    expect(detector.requests, 0);
  });

  test('stop during health check cannot start a capture timer', () async {
    detector.healthGate = Completer<bool>();
    final start = session.start();
    await flushDeviceEvents();
    session.stop();
    detector.healthGate!.complete(true);
    expect(await start, isFalse);
    expect(camera.captures, 0);
  });

  test(
    'Vietnamese obstacle warning and vibration preempt assistant speech',
    () async {
      detector.result = dangerDetection;
      expect(await session.speakAssistant('Đang giải thích'), isTrue);
      await session.start();
      await flushDeviceEvents();
      expect(tts.spoken.last.$1, contains('người'));
      expect(tts.spoken.last.$2, 3);
      expect(haptics, [DangerLevel.high]);
      expect(session.state, isA<SessionAlerting>());
      expect(await session.speakAssistant('Phản hồi mới'), isFalse);
      expect(await session.speakGuidance('Đi thẳng'), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(tts.spoken.where((s) => s.$2 == 3), hasLength(1));
    },
  );

  test(
    'STT stops TTS first and routes a final transcript through the callback',
    () async {
      voice.text = 'Đi đến công viên';
      await session.onTalkStart();
      expect(tts.silences, 1);
      expect(voice.starts, 1);
      expect(await session.speakAssistant('Không đọc khi đang nghe'), isFalse);
      await session.onTalkEnd();
      expect(session.isListening, isFalse);
      expect(commands.single.kind, VoiceCommandKind.destination);
      expect(commands.single.destination, 'công viên');
    },
  );

  test(
    'quick release waits for recognizer startup; duplicate release is ignored',
    () async {
      voice.startGate = Completer<void>();
      voice.text = 'Nhắc lại';
      final start = session.onTalkStart();
      final end = session.onTalkEnd();
      await session.onTalkEnd();
      expect(voice.stops, 0);
      voice.startGate!.complete();
      await Future.wait([start, end]);
      expect(voice.stops, 1);
      expect(commands.single.kind, VoiceCommandKind.repeat);
    },
  );

  test('microphone failure resets listening state', () async {
    voice.fail = true;
    await session.onTalkStart();
    expect(session.isListening, isFalse);
    expect(session.state.statusText, contains('micro'));
    expect(await session.speakAssistant('Có thể đọc lại'), isTrue);
  });

  test('pause cancels recognition and rejects a late transcript', () async {
    voice.stopGate = Completer<String?>();
    await session.onTalkStart();
    final end = session.onTalkEnd();
    await flushDeviceEvents();
    await session.pause();
    voice.stopGate!.complete('Đi đến công viên');
    await end;
    expect(commands, isEmpty);
    expect(voice.cancels, 1);
    expect(session.isListening, isFalse);
    expect(await session.speakAssistant('Không đọc khi pause'), isFalse);
  });

  test('perception vibrates but does not speak over active STT', () async {
    detector.result = dangerDetection;
    await session.onTalkStart();
    await session.start();
    await flushDeviceEvents();
    expect(haptics, [DangerLevel.high]);
    expect(tts.spoken, isEmpty);
    await session.onTalkEnd();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(tts.spoken.last.$2, 3);
  });
}
