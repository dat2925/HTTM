import 'package:flutter_dotenv/flutter_dotenv.dart';

enum DetectionMode { auto, device, server }

class AiConfig {
  AiConfig._();

  /// Read the server URL from the .env file.
  static String get serverUrl {
    const override = String.fromEnvironment('AI_SERVER_URL');
    return (override.isNotEmpty
            ? override
            : dotenv.env['AI_SERVER_URL'] ?? 'https://blindnav.xuanthieu.site')
        .replaceAll(RegExp(r'/+$'), '');
  }

  static DetectionMode get detectionMode {
    const override = String.fromEnvironment('DETECTION_MODE');
    final value = override.isNotEmpty
        ? override
        : (dotenv.isInitialized ? dotenv.env['DETECTION_MODE'] : null);
    return switch (value?.trim().toLowerCase()) {
      'device' => DetectionMode.device,
      'server' => DetectionMode.server,
      _ => DetectionMode.auto,
    };
  }

  static const defaultDeviceModel = 'httm_yolo11n_ft20.tflite';

  /// File name inside assets/models/, chosen with DEVICE_MODEL. Like the rest
  /// of .env it is bundled at build time, so switching models needs a rebuild.
  static String get deviceModel {
    const override = String.fromEnvironment('DEVICE_MODEL');
    final value = override.isNotEmpty
        ? override
        : (dotenv.isInitialized ? dotenv.env['DEVICE_MODEL'] : null);
    return deviceModelFileName(value) ?? defaultDeviceModel;
  }

  /// Accepts a bare `.tflite` file name only, never a path.
  static String? deviceModelFileName(String? value) {
    final name = value?.trim() ?? '';
    return RegExp(r'^[A-Za-z0-9._-]+\.tflite$').hasMatch(name) ? name : null;
  }

  static String get deviceModelAsset => 'assets/models/$deviceModel';
  static const deviceCaptureInterval = Duration(milliseconds: 500);
  static const Duration captureInterval = Duration(milliseconds: 900);
  static const Duration requestTimeout = Duration(seconds: 20);
  static const Duration detectTimeout = Duration(seconds: 4);
  static const Duration detectorRetryInterval = Duration(seconds: 10);
  static const Duration destinationConfirmTimeout = Duration(seconds: 30);
  static const Duration captureTimeout = Duration(seconds: 5);
  static const Duration cameraInitTimeout = Duration(seconds: 10);
  static const Duration warningCooldown = Duration(seconds: 12);

  /// Minimum pause between two spoken obstacle warnings, so route guidance
  /// and the destination dialogue still get airtime in a busy scene.
  static const Duration obstacleSpeechGap = Duration(seconds: 6);
  static const Duration obstacleSpeechHold = Duration(seconds: 3);
  static const Duration destinationReminderAfter = Duration(seconds: 12);
  static const int safeCyclesRequired = 3;

  static const Duration routeRefreshInterval = Duration(seconds: 30);
  static const double gpsMaxAccuracyMeters = 50.0;
  static const Duration guidanceRepeatInterval = Duration(seconds: 8);
  static const Duration guidanceMinGap = Duration(seconds: 3);
  static const Duration urgentRepeatInterval = Duration(seconds: 20);
  static const Duration gpsStaleAfter = Duration(seconds: 30);
}
