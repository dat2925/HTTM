import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';

import 'support/device_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'QR waits for capture, preserves external speech and discards stale YOLO',
    () async {
      final camera = FakeCamera()..captureGate = Completer<XFile>();
      final detector = FakeDetector()..deferred = true;
      final tts = RecordingTts();
      final session = SessionController(
        frameSource: camera,
        detectionService: detector,
        ttsService: tts,
        voiceService: FakeVoice(),
      );
      addTearDown(session.dispose);
      final frames = <Object>[];
      final sub = session.frames.listen(frames.add);
      await session.start();
      await flushDeviceEvents();
      final borrow = session.suspendCameraForQr();
      await flushDeviceEvents();
      expect(camera.closed, 0);
      camera.captureGate!.complete(XFile.fromData(Uint8List.fromList([1])));
      expect(await borrow, isTrue);
      expect(camera.closed, 1);
      // This capture was canceled before inference started.
      expect(detector.requests, 0);
      expect(
        await session.speakGuidance('Hướng dẫn bên ngoài vẫn hoạt động'),
        isTrue,
      );
      camera.captureGate = null;
      await session.resumeCameraAfterQr(restartPerception: true);
      await flushDeviceEvents();
      expect(camera.opened, 2);
      expect(detector.requests, 1);
      final secondBorrow = await session.suspendCameraForQr();
      await session.resumeCameraAfterQr(restartPerception: secondBorrow);
      detector.pending.first.complete(dangerDetection);
      await flushDeviceEvents();
      expect(frames, isEmpty);
      expect(tts.spoken.where((s) => s.$2 == 3), isEmpty);
      await sub.cancel();
    },
  );

  test(
    'QR lease cannot take the camera during active microphone input',
    () async {
      final session = SessionController(
        frameSource: FakeCamera(),
        detectionService: FakeDetector(),
        voiceService: FakeVoice(),
        ttsService: RecordingTts(),
      );
      addTearDown(session.dispose);
      await session.onTalkStart();
      await expectLater(
        session.suspendCameraForQr(),
        throwsA(isA<DeviceSessionException>()),
      );
    },
  );
}
