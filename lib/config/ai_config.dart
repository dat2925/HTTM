import 'package:flutter_dotenv/flutter_dotenv.dart';

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

  static const Duration captureInterval = Duration(milliseconds: 900);
  static const Duration requestTimeout = Duration(seconds: 20);
  static const Duration warningCooldown = Duration(seconds: 12);
  static const int safeCyclesRequired = 3;

  static const Duration routeRefreshInterval = Duration(seconds: 30);
  static const Duration gpsStaleAfter = Duration(seconds: 15);
}
