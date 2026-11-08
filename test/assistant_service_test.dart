import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_navigation/services/assistant_service.dart';

import 'assistant_test.dart' show MemoryCredentials;

http.Response pairedReply() => http.Response(
  jsonEncode({
    'access_token': 'test-device-token',
    'expires_at':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch /
        1000,
  }),
  200,
);

http.Response chatReply(http.Request request) => http.Response(
  jsonEncode({
    'request_id': jsonDecode(request.body)['request_id'],
    'text': 'Thông tin tham khảo',
    'proposals': [],
    'expires_at':
        DateTime.now().add(const Duration(seconds: 15)).millisecondsSinceEpoch /
        1000,
    'safety': 'advisory_only',
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class DelayedCredentials extends MemoryCredentials {
  final savingToken = Completer<void>();
  final releaseToken = Completer<void>();
  bool delayed = false;

  @override
  Future<void> write(String server, Map<String, dynamic> value) async {
    if (!delayed && value['token'] != null) {
      delayed = true;
      savingToken.complete();
      await releaseToken.future;
    }
    await super.write(server, value);
  }
}

void main() {
  test(
    'new enrollment waits until the previous server revocation finishes',
    () async {
      final revoke = Completer<http.Response>();
      var enrollments = 0;
      final service = AiAssistantService(
        credentials: MemoryCredentials(),
        serverUrl: () => 'https://backend.example',
        clientFactory: () => MockClient((request) async {
          if (request.url.path.endsWith('/unpair')) return revoke.future;
          enrollments++;
          return pairedReply();
        }),
      );
      addTearDown(service.dispose);
      await service.pair('test-enrollment-code');
      final unpairing = service.unpair();
      final pairing = service.pair('test-enrollment-code');
      await Future<void>.delayed(Duration.zero);
      expect(enrollments, 1);
      revoke.complete(http.Response('{}', 200));
      await Future.wait([pairing, unpairing]);
      expect(enrollments, 2);
      expect(service.paired, isTrue);
    },
  );

  test(
    'unpair rejects a late enrollment response without saving its token',
    () async {
      final pending = Completer<http.Response>();
      final requested = Completer<void>();
      final credentials = MemoryCredentials();
      final service = AiAssistantService(
        credentials: credentials,
        serverUrl: () => 'https://backend.example',
        clientFactory: () => MockClient((_) async {
          requested.complete();
          return pending.future;
        }),
      );
      addTearDown(service.dispose);
      final pairing = service.pair('test-enrollment-code');
      final rejected = expectLater(
        pairing,
        throwsA(
          isA<AssistantException>().having((e) => e.code, 'code', 'stale'),
        ),
      );
      await requested.future;
      await service.unpair();
      pending.complete(pairedReply());
      await rejected;
      expect(service.paired, isFalse);
      expect(credentials.record!['token'], isNull);
    },
  );

  test(
    'unpair wins over an in-progress credential write and app restart',
    () async {
      final credentials = DelayedCredentials();
      final service = AiAssistantService(
        credentials: credentials,
        serverUrl: () => 'https://backend.example',
        clientFactory: () => MockClient(
          (request) async => request.url.path.endsWith('/pair')
              ? pairedReply()
              : http.Response('{}', 200),
        ),
      );
      addTearDown(service.dispose);
      final pairing = service.pair('test-enrollment-code');
      final rejected = expectLater(pairing, throwsA(isA<AssistantException>()));
      await credentials.savingToken.future;
      final unpairing = service.unpair();
      expect(service.paired, isFalse);
      credentials.releaseToken.complete();
      await Future.wait([rejected, unpairing]);
      expect(credentials.record!['token'], isNull);
      final restored = AiAssistantService(
        credentials: credentials,
        serverUrl: () => 'https://backend.example',
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.paired, isFalse);
    },
  );

  test('dispose rejects a pending enrollment response', () async {
    final pending = Completer<http.Response>();
    final service = AiAssistantService(
      credentials: MemoryCredentials(),
      serverUrl: () => 'https://backend.example',
      clientFactory: () => MockClient((_) => pending.future),
    );
    final pairing = service.pair('test-enrollment-code');
    final rejected = expectLater(pairing, throwsA(isA<AssistantException>()));
    service.dispose();
    pending.complete(pairedReply());
    await rejected;
    expect(service.paired, isFalse);
  });

  test('expired persisted token never reaches the backend', () async {
    final credentials = MemoryCredentials()
      ..record = {
        'device_id': 'test-device',
        'token': 'expired-token',
        'expires_at': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      };
    var calls = 0;
    final service = AiAssistantService(
      credentials: credentials,
      serverUrl: () => 'https://backend.example',
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(service.dispose);
    await service.initialize();
    expect(service.paired, isFalse);
    await expectLater(
      service.chat('Xin chào', {}),
      throwsA(isA<AssistantException>()),
    );
    expect(calls, 0);
  });

  test(
    'unpair clears saved credentials even when revocation is unavailable',
    () async {
      final credentials = MemoryCredentials();
      final service = AiAssistantService(
        credentials: credentials,
        serverUrl: () => 'https://backend.example',
        clientFactory: () => MockClient(
          (request) async => request.url.path.endsWith('/pair')
              ? pairedReply()
              : http.Response('{}', 503),
        ),
      );
      addTearDown(service.dispose);
      await service.pair('test-enrollment-code');
      await service.setProactive(true);
      await expectLater(service.unpair(), throwsA(isA<AssistantException>()));
      expect(service.paired, isFalse);
      expect(service.proactiveEnabled, isFalse);
      expect(credentials.record!['token'], isNull);
      expect(credentials.record!['expires_at'], isNull);
    },
  );

  test('canceled chat cannot return a late response', () async {
    final pending = Completer<http.Response>();
    final requested = Completer<http.Request>();
    final service = AiAssistantService(
      credentials: MemoryCredentials(),
      serverUrl: () => 'https://backend.example',
      clientFactory: () => MockClient((request) async {
        if (request.url.path.endsWith('/pair')) return pairedReply();
        requested.complete(request);
        return pending.future;
      }),
    );
    addTearDown(service.dispose);
    await service.pair('test-enrollment-code');
    final asking = service.chat('Hỏi trợ lý', {});
    final request = await requested.future;
    service.cancel();
    final rejected = expectLater(
      asking,
      throwsA(isA<AssistantException>().having((e) => e.code, 'code', 'stale')),
    );
    pending.complete(chatReply(request));
    await rejected;
  });

  test(
    'debug HTTP enrollment requires explicit private-network opt-in',
    () async {
      final service = AiAssistantService(
        credentials: MemoryCredentials(),
        serverUrl: () => 'http://192.168.1.2:8000',
        clientFactory: () => MockClient((_) async => pairedReply()),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.pair('test-enrollment-code'),
        throwsA(isA<AssistantException>()),
      );
      await service.pair('test-enrollment-code', allowInsecure: true);
      expect(service.paired, isTrue);
    },
  );

  testWidgets('chat timeout closes the request and preserves pairing', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final service = AiAssistantService(
      credentials: MemoryCredentials(),
      serverUrl: () => 'https://backend.example',
      clientFactory: () => MockClient(
        (request) async =>
            request.url.path.endsWith('/pair') ? pairedReply() : pending.future,
      ),
    );
    await service.pair('test-enrollment-code');
    final rejected = expectLater(
      service.chat('Hỏi trợ lý', {}),
      throwsA(isA<AssistantException>()),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    await rejected;
    expect(service.paired, isTrue);
    pending.complete(http.Response('{}', 200));
    await tester.pump();
    service.dispose();
  });
}
