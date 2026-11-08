import 'dart:async';
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
  AiDetectionService({
    http.Client? client,
    Duration requestTimeout = AiConfig.requestTimeout,
  }) : assert(requestTimeout > Duration.zero),
       _client = client ?? http.Client(),
       _requestTimeout = requestTimeout;

  final http.Client _client;
  final Duration _requestTimeout;

  Future<bool> isHealthy() async {
    try {
      final response = await _client
          .get(Uri.parse('${AiConfig.serverUrl}/health'))
          .timeout(_requestTimeout);
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map<String, dynamic> && body['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  Future<DetectionResult> detect(XFile image) async {
    final abort = Completer<void>();
    try {
      // One deadline covers file preparation, upload, headers and response body.
      return await _detect(image, abort).timeout(
        _requestTimeout,
        onTimeout: () {
          abort.complete();
          throw const AiDetectionException(
            'AI Server phản hồi quá thời gian chờ.',
          );
        },
      );
    } on AiDetectionException {
      rethrow;
    } catch (_) {
      throw const AiDetectionException('Không thể kết nối AI Server.');
    }
  }

  Future<DetectionResult> _detect(XFile image, Completer<void> abort) async {
    final request = http.AbortableMultipartRequest(
      'POST',
      Uri.parse('${AiConfig.serverUrl}/detect'),
      abortTrigger: abort.future,
    );
    request.files.add(
      await http.MultipartFile.fromPath(
        'image',
        image.path,
        contentType: MediaType('image', 'jpeg'),
      ),
    );
    if (abort.isCompleted) throw http.RequestAbortedException(request.url);
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      developer.log(
        'Detection request failed: status=${response.statusCode}',
        name: 'AiDetectionService',
      );
      throw AiDetectionException(
        'AI Server lỗi (${response.statusCode}). Hãy thử lại.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid JSON response.');
    }
    return DetectionResult.fromJson(decoded);
  }

  void dispose() => _client.close();
}
