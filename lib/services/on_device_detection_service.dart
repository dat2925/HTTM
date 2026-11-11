import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:ultralytics_yolo/yolo.dart';

import '../config/ai_config.dart';
import '../models/detection_result.dart';
import 'ai_detection_service.dart';
import 'jpeg_orientation.dart';
import 'obstacle_rules.dart';

abstract interface class YoloEngine {
  Future<void> load();
  Future<Map<String, dynamic>> predict(
    Uint8List bytes, {
    required double confidence,
    required double iou,
  });
  Future<void> dispose();
}

/// A model is usable when it knows at least one obstacle class. The custom
/// model maps all ten of its classes; the COCO model maps only some of its 80,
/// and the rest are dropped per box, as the server does.
bool modelLabelsUsable(Object? labels) =>
    labels is List &&
    labels.any((label) => canonicalClassName(label.toString()) != null);

class UltralyticsYoloEngine implements YoloEngine {
  final _yolo = YOLO(
    modelPath: AiConfig.deviceModelAsset,
    task: YOLOTask.detect,
    useGpu: true,
    // Match Ultralytics' default max_det rather than the plugin's default 30.
    numItemsThreshold: 300,
  );

  @override
  Future<void> load() async {
    final metadata = await YOLO.inspectModel(AiConfig.deviceModelAsset);
    final labels = metadata['labels'];
    if (!modelLabelsUsable(labels)) {
      throw const AiDetectionException('Tên lớp trong mô hình không phù hợp.');
    }
    if (!await _yolo.loadModel()) {
      throw const AiDetectionException(
        'Không thể nạp mô hình nhận diện trên máy.',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> predict(
    Uint8List bytes, {
    required double confidence,
    required double iou,
  }) =>
      _yolo.predict(bytes, confidenceThreshold: confidence, iouThreshold: iou);

  @override
  Future<void> dispose() => _yolo.dispose();
}

class OnDeviceDetector {
  OnDeviceDetector({YoloEngine? engine})
    : _engine = engine ?? UltralyticsYoloEngine();

  final YoloEngine _engine;
  Future<void>? _preparation;

  Future<void> prepare() => _preparation ??= _load();

  Future<void> _load() async {
    try {
      await _engine.load();
    } catch (_) {
      throw const AiDetectionException(
        'Không thể nạp mô hình nhận diện trên máy.',
      );
    }
  }

  Future<DetectionResult> detect(XFile image) async {
    try {
      await prepare();
      final bytes = await uprightImageBytes(await image.readAsBytes());
      final result = await _engine.predict(bytes, confidence: 0.35, iou: 0.45);
      final size = result['imageSize'] as Map;
      final width = (size['width'] as num).toInt();
      final height = (size['height'] as num).toInt();
      if (width <= 0 || height <= 0) throw const FormatException('imageSize');
      final objects = <DetectedObject>[];
      for (final raw in result['boxes'] as List) {
        final box = raw as Map;
        final className = canonicalClassName(box['class'] as String);
        if (className == null) continue;
        final x1 = (box['x1_norm'] as num).toDouble();
        final y1 = (box['y1_norm'] as num).toDouble();
        final x2 = (box['x2_norm'] as num).toDouble();
        final y2 = (box['y2_norm'] as num).toDouble();
        final area = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
        final position = positionFor((x1 + x2) / 2);
        objects.add(
          DetectedObject.fromJson({
            'class_name': className,
            'confidence': _round((box['confidence'] as num).toDouble(), 4),
            'position': position,
            'danger': dangerFor(area, className, position, y2),
            'area_ratio': _round(area, 4),
            'x1': _round(x1 * width, 2),
            'y1': _round(y1 * height, 2),
            'x2': _round(x2 * width, 2),
            'y2': _round(y2 * height, 2),
          }),
        );
      }
      return DetectionResult(
        imageWidth: width,
        imageHeight: height,
        objects: objects,
      );
    } on AiDetectionException {
      rethrow;
    } catch (_) {
      throw const AiDetectionException('Nhận diện vật cản trên máy bị lỗi.');
    }
  }

  Future<void> dispose() async {
    try {
      await _preparation;
    } catch (_) {
      // A failed load can still leave native resources to release.
    }
    await _engine.dispose();
  }
}

double _round(double value, int digits) {
  if (!value.isFinite) throw const FormatException('Non-finite detection');
  // Python round uses ties-to-even on the exact binary input.
  final data = ByteData(8)..setFloat64(0, value);
  final high = data.getUint32(0);
  final low = data.getUint32(4);
  final encodedExponent = (high >> 20) & 0x7ff;
  final fraction = (BigInt.from(high & 0xfffff) << 32) | BigInt.from(low);
  final mantissa = encodedExponent == 0
      ? fraction
      : fraction | (BigInt.one << 52);
  final exponent = encodedExponent == 0 ? -1074 : encodedExponent - 1075;
  final scale = BigInt.from(10).pow(digits);
  final scaled = mantissa * scale;
  BigInt rounded;
  if (exponent >= 0) {
    rounded = scaled << exponent;
  } else {
    final divisor = BigInt.one << -exponent;
    rounded = scaled ~/ divisor;
    final twiceRemainder = (scaled % divisor) << 1;
    if (twiceRemainder > divisor ||
        (twiceRemainder == divisor && rounded.isOdd)) {
      rounded += BigInt.one;
    }
  }
  final result = rounded.toDouble() / scale.toDouble();
  return (high & 0x80000000) == 0 ? result : -result;
}
