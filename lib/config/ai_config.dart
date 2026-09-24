import 'package:flutter_dotenv/flutter_dotenv.dart';

class AiConfig {
  AiConfig._();

  /// Read the server URL from the .env file.
  static String get serverUrl =>
      dotenv.env['AI_SERVER_URL'] ?? 'http://172.11.42.144:8000';

  static const Duration captureInterval = Duration(milliseconds: 900);
  static const Duration requestTimeout = Duration(seconds: 12);
  static const Duration warningCooldown = Duration(seconds: 3);
  static const int safeCyclesRequired = 3;

  /// Demo destination for the GPS route heuristic (no real Directions API
  /// backend exists yet).
  static const double demoDestinationLat = 21.0285;
  static const double demoDestinationLng = 105.8542;
}
