class AiConfig {
  AiConfig._();

  /// Override without changing source code:
  /// flutter run --dart-define=AI_SERVER_URL=http://192.168.1.10:8000
  static const String serverUrl = String.fromEnvironment(
    'AI_SERVER_URL',
    defaultValue: 'http://172.11.42.144:8000',
  );

  static const Duration captureInterval = Duration(milliseconds: 900);
  static const Duration requestTimeout = Duration(seconds: 12);
  static const Duration warningCooldown = Duration(seconds: 3);
  static const int safeCyclesRequired = 3;
}
