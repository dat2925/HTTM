import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../config/ai_config.dart';
import '../models/placemark.dart';

class GeocodingException implements Exception {
  const GeocodingException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Talks to `ai_server`'s `/geocode` proxy so the app never has to embed
/// the Nominatim usage-policy User-Agent header itself.
class GeocodingService {
  GeocodingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Placemark> search(String query) async {
    try {
      final uri = Uri.parse(
        '${AiConfig.serverUrl}/geocode',
      ).replace(queryParameters: {'q': query});
      final response = await _client.get(uri).timeout(AiConfig.requestTimeout);
      if (response.statusCode != 200) {
        developer.log(
          'Geocode request failed: status=${response.statusCode}, '
          'body=${response.body}',
          name: 'GeocodingService',
        );
        throw GeocodingException('Không tìm thấy địa điểm "$query".');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        throw const FormatException('Invalid geocode response.');
      }
      return Placemark.fromJson(decoded);
    } on GeocodingException {
      rethrow;
    } catch (_) {
      throw const GeocodingException('Không thể tìm địa điểm lúc này.');
    }
  }

  void dispose() => _client.close();
}
