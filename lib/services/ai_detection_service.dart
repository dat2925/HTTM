import 'dart:convert';
import 'dart:developer' as developer;

import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config/ai_config.dart';
import '../models/detection_result.dart';

class AiDetectionException implements Exception {
  const AiDetectionException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AiDetectionService {
  AiDetectionService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<bool> isHealthy() async {
    try {
      final response = await _client
          .get(Uri.parse('${AiConfig.serverUrl}/health'))
          .timeout(AiConfig.requestTimeout);
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> && body['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  Future<DetectionResult> detect(XFile image) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${AiConfig.serverUrl}/detect'),
      );
      request.files.add(
        await http.MultipartFile.fromPath(
          'image',
          image.path,
          contentType: MediaType('image', 'jpeg'),
        ),
      );
      final streamed = await _client
          .send(request)
          .timeout(AiConfig.requestTimeout);
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode != 200) {
        developer.log(
          'Detection request failed: status=${response.statusCode}, '
          'body=${response.body}',
          name: 'AiDetectionService',
        );
        throw AiDetectionException(
          'AI Server lỗi (${response.statusCode}): ${response.body}',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid JSON response.');
      }
      return DetectionResult.fromJson(decoded);
    } on AiDetectionException {
      rethrow;
    } catch (_) {
      throw const AiDetectionException('Không thể kết nối AI Server.');
    }
  }

  void dispose() => _client.close();
}
