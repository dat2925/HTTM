import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/config/ai_config.dart';
import 'package:smart_navigation/services/ai_detection_service.dart';
import 'package:smart_navigation/services/detection_backend.dart';
import 'package:smart_navigation/services/on_device_detection_service.dart';

import 'on_device_detection_test.dart' show FakeYoloEngine;
import 'support/device_fakes.dart';

void main() {
  final image = XFile.fromData(Uint8List.fromList([1, 2, 3]));

  test(
    'auto prepares once and chooses device without consulting server',
    () async {
      final engine = FakeYoloEngine();
      final server = FakeDetector()..healthy = false;
      final service = HybridDetectionService(
        server: server,
        device: OnDeviceDetector(engine: engine),
      );
      expect(await service.isHealthy(), isTrue);
      expect(await service.isHealthy(), isTrue);
      expect(engine.loads, 1);
      expect(service.backend, 'device');
      await service.detect(image);
      expect(server.requests, 0);
      expect(engine.predictions, 1);
    },
  );

  test('auto falls back permanently when prepare fails', () async {
    final engine = FakeYoloEngine()..failLoad = true;
    final server = FakeDetector();
    final service = HybridDetectionService(
      server: server,
      device: OnDeviceDetector(engine: engine),
    );
    expect(await service.isHealthy(), isTrue);
    expect(service.backend, 'server');
    engine.failLoad = false;
    expect(await service.isHealthy(), isTrue);
    expect(await service.detect(image), same(emptyDetection));
    expect(engine.loads, 1);
    expect(engine.predictions, 0);
  });

  test(
    'three consecutive errors switch to server; failed call still throws',
    () async {
      final engine = FakeYoloEngine()..failPredict = true;
      final server = FakeDetector();
      final service = HybridDetectionService(
        server: server,
        device: OnDeviceDetector(engine: engine),
      );
      await service.isHealthy();
      for (var i = 0; i < 3; i++) {
        await expectLater(
          service.detect(image),
          throwsA(isA<AiDetectionException>()),
        );
        expect(service.backend, i < 2 ? 'device' : 'server');
      }
      engine.failPredict = false;
      expect(await service.isHealthy(), isTrue);
      expect(await service.detect(image), same(emptyDetection));
      expect(engine.predictions, 3);
      expect(server.requests, 1);
    },
  );

  test(
    'successful device detection resets consecutive error counter',
    () async {
      final engine = FakeYoloEngine()..failPredict = true;
      final service = HybridDetectionService(
        server: FakeDetector(),
        device: OnDeviceDetector(engine: engine),
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          service.detect(image),
          throwsA(isA<AiDetectionException>()),
        );
      }
      engine.failPredict = false;
      await service.detect(image);
      engine.failPredict = true;
      await expectLater(
        service.detect(image),
        throwsA(isA<AiDetectionException>()),
      );
      expect(service.backend, 'device');
    },
  );

  test(
    'device mode missing model is unhealthy and never uses server',
    () async {
      final server = FakeDetector();
      final engine = FakeYoloEngine()..failLoad = true;
      final service = HybridDetectionService(
        server: server,
        device: OnDeviceDetector(engine: engine),
        mode: DetectionMode.device,
      );
      expect(await service.isHealthy(), isFalse);
      expect(service.backend, 'device');
      await expectLater(
        service.detect(image),
        throwsA(isA<AiDetectionException>()),
      );
      expect(server.requests, 0);
    },
  );

  test('device mode prediction failures never switch to server', () async {
    final server = FakeDetector();
    final engine = FakeYoloEngine()..failPredict = true;
    final service = HybridDetectionService(
      server: server,
      device: OnDeviceDetector(engine: engine),
      mode: DetectionMode.device,
    );
    for (var i = 0; i < 4; i++) {
      await expectLater(
        service.detect(image),
        throwsA(isA<AiDetectionException>()),
      );
    }
    expect(service.backend, 'device');
    expect(server.requests, 0);
  });

  test('server mode never loads, predicts or disposes device', () async {
    final engine = FakeYoloEngine()..failLoad = true;
    final server = FakeDetector();
    final service = HybridDetectionService(
      server: server,
      device: OnDeviceDetector(engine: engine),
      mode: DetectionMode.server,
    );
    expect(await service.isHealthy(), isTrue);
    expect(service.backend, 'server');
    expect(await service.detect(image), same(emptyDetection));
    await service.dispose();
    expect(engine.loads, 0);
    expect(engine.predictions, 0);
    expect(engine.disposals, 0);
  });

  test('absent optional device uses server only in auto mode', () async {
    expect(
      await HybridDetectionService(server: FakeDetector()).isHealthy(),
      isTrue,
    );
    expect(
      await HybridDetectionService(
        server: FakeDetector(),
        mode: DetectionMode.device,
      ).isHealthy(),
      isFalse,
    );
  });
}
