import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../config/ai_config.dart';
import '../models/walking_route.dart';

class RoutePlanningException implements Exception {
  const RoutePlanningException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Fetches a real turn-by-turn route from `ai_server`'s `/route` proxy
/// (Valhalla pedestrian). Rejects older waypoint-only/driving responses.
class RoutePlanningService {
  RoutePlanningService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<WalkingRoute> plan({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    try {
      final uri = Uri.parse('${AiConfig.serverUrl}/route').replace(
        queryParameters: {
          'from_lat': '$fromLat',
          'from_lng': '$fromLng',
          'to_lat': '$toLat',
          'to_lng': '$toLng',
        },
      );
      final response = await _client.get(uri).timeout(AiConfig.requestTimeout);
      if (response.statusCode != 200) {
        developer.log(
          'Route request failed: status=${response.statusCode}, '
          'body=${response.body}',
          name: 'RoutePlanningService',
        );
        throw const RoutePlanningException('Không tìm được tuyến đường.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        throw const FormatException('Invalid route response.');
      }
      if (decoded['profile'] != 'pedestrian' || decoded['geometry'] is! List) {
        throw const RoutePlanningException(
          'Server chưa hỗ trợ tuyến đi bộ có bản đồ. Hãy cập nhật AI Server.',
        );
      }
      return WalkingRoute.fromJson(decoded);
    } on RoutePlanningException {
      rethrow;
    } catch (_) {
      throw const RoutePlanningException('Không thể tính tuyến đường lúc này.');
    }
  }

  void dispose() => _client.close();
}
