import 'package:camera/camera.dart';

import '../config/ai_config.dart';
import '../models/detection_result.dart';
import 'ai_detection_service.dart';
import 'on_device_detection_service.dart';

abstract interface class ObstacleDetector {
  Future<bool> isHealthy();
  Future<DetectionResult> detect(XFile image);
  String get backend;
}

class HybridDetectionService implements ObstacleDetector {
  HybridDetectionService({
    required this._server,
    this._device,
    this._mode = DetectionMode.auto,
  });

  final ObstacleDetector _server;
  final OnDeviceDetector? _device;
  final DetectionMode _mode;
  Future<bool>? _preparation;
  bool _deviceReady = false;
  bool _serverOnly = false;
  int _deviceErrors = 0;

  @override
  String get backend =>
      _mode == DetectionMode.device || (_deviceReady && !_serverOnly)
      ? 'device'
      : 'server';

  Future<bool> _prepare() async {
    try {
      final device = _device;
      if (device == null) return false;
      await device.prepare();
      _deviceReady = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isHealthy() async {
    if (_mode != DetectionMode.server && !_serverOnly) {
      if (await (_preparation ??= _prepare())) return true;
      if (_mode == DetectionMode.device) return false;
    }
    try {
      return await _server.isHealthy();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DetectionResult> detect(XFile image) async {
    if (_mode != DetectionMode.server && !_serverOnly) {
      await (_preparation ??= _prepare());
      if (_deviceReady) {
        try {
          final result = await _device!.detect(image);
          _deviceErrors = 0;
          return result;
        } catch (_) {
          if (++_deviceErrors >= 3 && _mode == DetectionMode.auto) {
            _serverOnly = true;
          }
          throw const AiDetectionException(
            'Nhận diện trên máy tạm thời bị lỗi.',
          );
        }
      }
      if (_mode == DetectionMode.device) {
        throw const AiDetectionException(
          'Không thể nạp mô hình nhận diện trên máy.',
        );
      }
    }
    return _server.detect(image);
  }

  Future<void> dispose() async {
    await _preparation;
    if (_mode != DetectionMode.server) await _device?.dispose();
    final server = _server;
    if (server is AiDetectionService) server.dispose();
  }
}
