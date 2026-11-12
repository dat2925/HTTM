import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/services/ai_detection_service.dart';
import 'package:smart_navigation/services/jpeg_orientation.dart';
import 'package:smart_navigation/services/on_device_detection_service.dart';

class FakeYoloEngine implements YoloEngine {
  int loads = 0, predictions = 0, disposals = 0;
  bool failLoad = false, failPredict = false;
  Uint8List? received;
  Map<String, dynamic> result = {
    'imageSize': {'width': 1000, 'height': 500},
    'boxes': <Map<String, dynamic>>[],
  };

  @override
  Future<void> load() async {
    loads++;
    if (failLoad) throw StateError('load');
  }

  @override
  Future<Map<String, dynamic>> predict(
    Uint8List bytes, {
    required double confidence,
    required double iou,
  }) async {
    predictions++;
    received = bytes;
    expect(confidence, 0.35);
    expect(iou, 0.45);
    if (failPredict) throw StateError('predict');
    return result;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

Map<String, dynamic> pluginBox(String name, List<double> xyxy) => {
  'class': name,
  'className': name,
  'confidence': 0.87654,
  // Deliberately different: mapping must use normalized coordinates.
  'x1': 9999.0, 'y1': 9999.0, 'x2': 9999.0, 'y2': 9999.0,
  'x1_norm': xyxy[0], 'y1_norm': xyxy[1],
  'x2_norm': xyxy[2], 'y2_norm': xyxy[3],
};

Uint8List exifJpeg(int orientation, {bool little = true}) {
  final tiff = ByteData(26);
  final order = little ? Endian.little : Endian.big;
  tiff.setUint16(0, little ? 0x4949 : 0x4d4d, order);
  tiff.setUint16(2, 42, order);
  tiff.setUint32(4, 8, order);
  tiff.setUint16(8, 1, order);
  tiff.setUint16(10, 0x0112, order);
  tiff.setUint16(12, 3, order);
  tiff.setUint32(14, 1, order);
  tiff.setUint16(18, orientation, order);
  return Uint8List.fromList([
    0xff,
    0xd8,
    0xff,
    0xe1,
    0,
    34,
    0x45,
    0x78,
    0x69,
    0x66,
    0,
    0,
    ...tiff.buffer.asUint8List(),
    0xff,
    0xd9,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mapping preserves order, drops unknowns, scales and rounds', () async {
    final engine = FakeYoloEngine();
    engine.result['boxes'] = [
      pluginBox('Xe hoi', [0.7, 0, 1, 0.8]),
      pluginBox('unknown', [0, 0, 1, 1]),
      pluginBox('O ga', [0.45, 0.56, 0.55, 0.66]),
      pluginBox('Cot', [0.05, 0.1, 0.15, 0.2]),
    ];
    final detector = OnDeviceDetector(engine: engine);
    await detector.prepare();
    final result = await detector.detect(
      XFile.fromData(Uint8List.fromList([1, 2])),
    );
    expect(engine.loads, 1);
    expect(engine.received, [1, 2]);
    expect(result.imageWidth, 1000);
    expect(result.imageHeight, 500);
    expect(result.objects.map((o) => o.className), ['car', 'pothole', 'pole']);
    final pothole = result.objects[1];
    expect(pothole.position, 'center');
    expect(pothole.danger, DangerLevel.high);
    expect(pothole.areaRatio, 0.01);
    expect(pothole.confidence, 0.8765);
    expect(
      [pothole.x1, pothole.y1, pothole.x2, pothole.y2],
      [450, 280, 550, 330],
    );
    expect(result.objects.last.danger, DangerLevel.low);
    await detector.dispose();
    expect(engine.disposals, 1);
  });

  test(
    'does not truncate the server object list to plugin default 30',
    () async {
      final engine = FakeYoloEngine();
      engine.result['boxes'] = List.generate(
        40,
        (_) => pluginBox('Nguoi', [0, 0, 0.1, 0.1]),
      );
      final result = await OnDeviceDetector(
        engine: engine,
      ).detect(XFile.fromData(Uint8List(1)));
      expect(result.objects, hasLength(40));
    },
  );

  test(
    'prepare failure is cached and wrapped; resources can be disposed',
    () async {
      final engine = FakeYoloEngine()..failLoad = true;
      final detector = OnDeviceDetector(engine: engine);
      await expectLater(
        detector.prepare(),
        throwsA(isA<AiDetectionException>()),
      );
      await expectLater(
        detector.prepare(),
        throwsA(isA<AiDetectionException>()),
      );
      expect(engine.loads, 1);
      await detector.dispose();
      expect(engine.disposals, 1);
    },
  );

  test('prediction and malformed response failures are wrapped', () async {
    final engine = FakeYoloEngine()..failPredict = true;
    final detector = OnDeviceDetector(engine: engine);
    final image = XFile.fromData(Uint8List(1));
    await expectLater(
      detector.detect(image),
      throwsA(isA<AiDetectionException>()),
    );
    engine.failPredict = false;
    engine.result = {};
    await expectLater(
      detector.detect(image),
      throwsA(isA<AiDetectionException>()),
    );
  });

  for (final little in [true, false]) {
    for (var orientation = 1; orientation <= 8; orientation++) {
      test('EXIF $orientation, little endian $little', () {
        expect(
          jpegExifOrientation(exifJpeg(orientation, little: little)),
          orientation,
        );
      });
    }
  }

  test('rounding follows Python ties-to-even', () async {
    final engine = FakeYoloEngine();
    engine.result['imageSize'] = {'width': 1, 'height': 1};
    engine.result['boxes'] = [
      pluginBox('Nguoi', [0.125, 0.375, 0.625, 0.875])
        ..['confidence'] = 0.03125,
    ];
    final result = await OnDeviceDetector(
      engine: engine,
    ).detect(XFile.fromData(Uint8List(1)));
    final object = result.objects.single;
    expect(
      [object.x1, object.y1, object.x2, object.y2],
      [0.12, 0.38, 0.62, 0.88],
    );
    expect(object.confidence, 0.0312);
  });

  test('EXIF invalid headers and truncated offsets return 1', () {
    final valid = exifJpeg(6);
    for (var i = 0; i < valid.length - 2; i++) {
      expect(jpegExifOrientation(Uint8List.sublistView(valid, 0, i)), 1);
    }
    expect(jpegExifOrientation(Uint8List.fromList([1, 2, 3])), 1);
    expect(jpegExifOrientation(exifJpeg(0)), 1);
    expect(jpegExifOrientation(exifJpeg(9)), 1);
    for (final offset in [12, 14, 20, 24, 26]) {
      final bad = exifJpeg(6)..[offset] = 0xff;
      expect(jpegExifOrientation(bad), 1);
    }
  });

  test('EXIF scans past another APP segment', () {
    final jpeg = exifJpeg(8);
    final bytes = Uint8List.fromList([
      ...jpeg.take(2),
      0xff,
      0xe0,
      0,
      4,
      0,
      0,
      ...jpeg.skip(2),
    ]);
    expect(jpegExifOrientation(bytes), 8);
  });

  test(
    'upright bytes retain identity; decode failure keeps original',
    () async {
      final upright = exifJpeg(1);
      expect(identical(await uprightImageBytes(upright), upright), isTrue);
      final invalidPixels = exifJpeg(6);
      expect(
        identical(await uprightImageBytes(invalidPixels), invalidPixels),
        isTrue,
      );
    },
  );
}
