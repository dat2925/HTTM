import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../config/ai_config.dart';
import '../models/assistant_state.dart';

String assistantUuid() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class AssistantException implements Exception {
  const AssistantException(this.message, {this.code = 'unavailable'});
  final String message;
  final String code;
  @override
  String toString() => message;
}

class AssistantCredentialStore {
  const AssistantCredentialStore();
  static const _storage = FlutterSecureStorage();
  Future<Map<String, dynamic>?> read(String server) async {
    final raw = await _storage.read(key: 'assistant:$server');
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw));
  }

  Future<void> write(String server, Map<String, dynamic> record) =>
      _storage.write(key: 'assistant:$server', value: jsonEncode(record));
}

class AiAssistantService {
  AiAssistantService({
    AssistantCredentialStore? credentials,
    String Function()? serverUrl,
    http.Client Function()? clientFactory,
  }) : _credentials = credentials ?? const AssistantCredentialStore(),
       _serverUrl = serverUrl ?? (() => AiConfig.serverUrl),
       _clientFactory = clientFactory ?? http.Client.new;
  final AssistantCredentialStore _credentials;
  final String Function() _serverUrl;
  final http.Client Function() _clientFactory;
  String? _token;
  DateTime? _expiresAt;
  String _deviceId = assistantUuid();
  String _conversationId = assistantUuid();
  bool proactiveEnabled = false;
  bool allowInsecureDev = false;
  int _generation = 0;
  int _pairGeneration = 0;
  bool _disposed = false;
  http.Client? _activeClient;
  http.Client? _pairClient;
  Future<void>? _credentialWrite;
  Future<void>? _unpairing;
  bool get paired =>
      _token != null &&
      _expiresAt != null &&
      _expiresAt!.isAfter(DateTime.now());

  Future<void> initialize() async {
    final generation = _pairGeneration;
    try {
      final record = await _credentials.read(_serverUrl());
      if (_disposed || generation != _pairGeneration) return;
      if (record == null) return;
      _deviceId = record['device_id'] as String? ?? _deviceId;
      _token = record['token'] as String?;
      _expiresAt = DateTime.tryParse(record['expires_at'] as String? ?? '');
      proactiveEnabled = record['proactive'] == true;
      allowInsecureDev = kDebugMode && record['allow_insecure_dev'] == true;
    } catch (_) {
      if (!_disposed && generation == _pairGeneration) _token = null;
    }
  }

  void _checkTransport() {
    final uri = Uri.parse(_serverUrl());
    if (uri.scheme == 'https' && uri.userInfo.isEmpty) return;
    final pieces = uri.host.split('.').map(int.tryParse).toList();
    final private =
        uri.host == 'localhost' ||
        uri.host == '::1' ||
        (pieces.length == 4 &&
            pieces.every((p) => p != null && p >= 0 && p <= 255) &&
            (pieces[0] == 127 ||
                pieces[0] == 10 ||
                (pieces[0] == 192 && pieces[1] == 168) ||
                (pieces[0] == 172 && pieces[1]! >= 16 && pieces[1]! <= 31)));
    if (kDebugMode &&
        allowInsecureDev &&
        private &&
        uri.scheme == 'http' &&
        uri.userInfo.isEmpty) {
      return;
    }
    throw const AssistantException(
      'Trợ lý cần HTTPS. Bản debug có thể cho phép HTTP mạng nội bộ trong cài đặt.',
      code: 'insecure_transport',
    );
  }

  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
    int? generation,
    int? pairGeneration,
  }) async {
    _checkTransport();
    if (authenticated && !paired) {
      throw const AssistantException(
        'Hãy ghép nối trợ lý trước.',
        code: 'unauthorized',
      );
    }
    final client = _clientFactory();
    if (generation != null) _activeClient = client;
    if (pairGeneration != null) _pairClient = client;
    try {
      final uri = Uri.parse('${_serverUrl()}/assistant/$path');
      final headers = {
        'Content-Type': 'application/json',
        if (authenticated) 'Authorization': 'Bearer $_token',
      };
      final response =
          await (body == null
                  ? client.get(uri, headers: headers)
                  : client.post(uri, headers: headers, body: jsonEncode(body)))
              .timeout(const Duration(seconds: 30));
      if (generation != null && generation != _generation) {
        throw const AssistantException('Phản hồi đã cũ.', code: 'stale');
      }
      if (pairGeneration != null) _checkPairGeneration(pairGeneration);
      if (response.body.length > 64000) {
        throw const AssistantException('Phản hồi vượt giới hạn.');
      }
      final json = Map<String, dynamic>.from(jsonDecode(response.body));
      if (response.statusCode != 200) {
        if (response.statusCode == 401 && authenticated) {
          _token = null;
          _expiresAt = null;
          await _save();
        }
        final error = json['error'];
        throw AssistantException(
          error is Map
              ? (error['message'] as String? ??
                    'Trợ lý tạm thời không khả dụng.')
              : 'Trợ lý tạm thời không khả dụng.',
          code: error is Map
              ? error['code'] as String? ?? 'unavailable'
              : 'unavailable',
        );
      }
      return json;
    } on AssistantException {
      rethrow;
    } catch (_) {
      if (pairGeneration != null) _checkPairGeneration(pairGeneration);
      throw const AssistantException(
        'Không kết nối được trợ lý hoặc phản hồi quá chậm. Dẫn đường vẫn hoạt động.',
      );
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
      if (identical(_pairClient, client)) _pairClient = null;
    }
  }

  Future<void> pair(String code, {bool allowInsecure = false}) async {
    _cancelPairing();
    final generation = _pairGeneration;
    _checkPairGeneration(generation);
    try {
      await _unpairing;
    } catch (_) {
      // A fresh enrollment may recover after an unconfirmed old revocation.
    }
    _checkPairGeneration(generation);
    allowInsecureDev = kDebugMode && allowInsecure;
    final response = await _request(
      'pair',
      authenticated: false,
      pairGeneration: generation,
      body: {'code': code.trim(), 'device_id': _deviceId},
    );
    _checkPairGeneration(generation);
    _token = response['access_token'] as String;
    _expiresAt = DateTime.fromMillisecondsSinceEpoch(
      ((response['expires_at'] as num) * 1000).round(),
      isUtc: true,
    );
    await _save();
    _checkPairGeneration(generation);
  }

  Future<void> setProactive(bool enabled) async {
    proactiveEnabled = enabled;
    await _save();
  }

  void _checkPairGeneration(int generation) {
    if (_disposed || generation != _pairGeneration) {
      throw const AssistantException(
        'Yêu cầu ghép nối đã bị hủy.',
        code: 'stale',
      );
    }
  }

  void _cancelPairing() {
    ++_pairGeneration;
    _pairClient?.close();
    _pairClient = null;
  }

  Future<void> _save() => _writeCredentials(_serverUrl(), {
    'device_id': _deviceId,
    'token': _token,
    'expires_at': _expiresAt?.toIso8601String(),
    'proactive': proactiveEnabled,
    'allow_insecure_dev': allowInsecureDev,
  });

  Future<void> _writeCredentials(
    String server,
    Map<String, dynamic> record,
  ) async {
    final previous = _credentialWrite;
    final completed = Completer<void>();
    _credentialWrite = completed.future;
    try {
      await previous;
      await _credentials.write(server, record);
    } finally {
      if (identical(_credentialWrite, completed.future)) {
        _credentialWrite = null;
      }
      completed.complete();
    }
  }

  Future<void> unpair() {
    _cancelPairing();
    cancel();
    final pending = _unpairing;
    if (pending != null) return pending;
    // Capture the authenticated request before clearing the local credential.
    final revoke = paired ? _request('unpair', body: {}) : null;
    _token = null;
    _expiresAt = null;
    proactiveEnabled = false;
    return _unpairing = Future.wait<void>([
      if (revoke != null) revoke.then<void>((_) {}),
      _save(),
    ]).then<void>((_) {}).whenComplete(() => _unpairing = null);
  }

  Future<void> reset() async {
    cancel();
    _conversationId = assistantUuid();
    if (paired) await _request('reset', body: {});
  }

  Future<AssistantReply> chat(
    String message,
    Map<String, dynamic> context, {
    Uint8List? image,
    bool proactive = false,
    String? event,
  }) async {
    cancel();
    final generation = _generation;
    final requestId = assistantUuid();
    final response = await _request(
      'chat',
      generation: generation,
      body: {
        'request_id': requestId,
        'conversation_id': _conversationId,
        'message': message,
        'mode': proactive ? 'proactive' : 'user',
        'event': event,
        'context': context,
        'image_base64': image == null ? null : base64Encode(image),
      },
    );
    final reply = AssistantReply.fromJson(response);
    if (reply.requestId != requestId ||
        reply.expiresAt.isBefore(DateTime.now())) {
      throw const AssistantException(
        'Phản hồi đã cũ. Hãy hỏi lại.',
        code: 'stale',
      );
    }
    return reply;
  }

  void cancel() {
    ++_generation;
    _activeClient?.close();
    _activeClient = null;
  }

  void dispose() {
    _disposed = true;
    _cancelPairing();
    cancel();
  }
}
