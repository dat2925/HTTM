import 'dart:convert';

/// QR enrolls against the configured backend only; it cannot redirect tokens
/// or replace AI_SERVER_URL. It contains no OpenAI key or signing secret.
class PairingQr {
  static String? codeFrom(String raw) {
    if (raw.length > 4096) return null;
    final text = raw.trim();
    try {
      final data = jsonDecode(text);
      if (data is! Map ||
          data['type'] != 'smart_navigation_pairing' ||
          data['version'] != 1 ||
          data['pairing_code'] is! String ||
          data.keys.any(
            (key) => !['type', 'version', 'pairing_code'].contains(key),
          )) {
        return null;
      }
      return _valid(data['pairing_code'] as String);
    } on FormatException {
      return _valid(text);
    }
  }

  static String? _valid(String code) =>
      RegExp(r'^[A-Za-z0-9_-]{12,128}$').hasMatch(code) ? code : null;
}
