import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_navigation/controllers/assistant_controller.dart';
import 'package:smart_navigation/models/assistant_state.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/placemark.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/services/assistant_policy.dart';
import 'package:smart_navigation/services/assistant_service.dart';

class MemoryCredentials extends AssistantCredentialStore {
  Map<String, dynamic>? record;
  @override
  Future<Map<String, dynamic>?> read(String server) async => record;
  @override
  Future<void> write(String server, Map<String, dynamic> value) async {
    record = value;
  }
}

class FakeAssistant extends AiAssistantService {
  bool enabled = true;
  AssistantReply? reply;
  Completer<AssistantReply>? pending;
  int calls = 0;
  @override
  bool get paired => enabled;
  @override
  Future<void> initialize() async {}
  @override
  Future<AssistantReply> chat(
    String message,
    Map<String, dynamic> context, {
    dynamic image,
    bool proactive = false,
    String? event,
  }) {
    calls++;
    return pending?.future ??
        Future.value(
          reply ??
              AssistantReply(
                requestId: 'test',
                text: 'Mô tả tham khảo',
                expiresAt: DateTime.now().add(const Duration(seconds: 15)),
              ),
        );
  }

  @override
  void cancel() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'API sends a device bearer token to backend only and keeps it out of prompts',
    () async {
      final credentials = MemoryCredentials();
      final requests = <http.Request>[];
      final service = AiAssistantService(
        credentials: credentials,
        serverUrl: () => 'https://backend.example',
        clientFactory: () => MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/pair')) {
            return http.Response(
              jsonEncode({
                'access_token': 'device-token',
                'expires_at':
                    DateTime.now()
                        .add(const Duration(hours: 1))
                        .millisecondsSinceEpoch /
                    1000,
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          final body = jsonDecode(request.body);
          return http.Response(
            jsonEncode({
              'request_id': body['request_id'],
              'text': 'Câu trả lời',
              'proposals': [],
              'expires_at':
                  DateTime.now()
                      .add(const Duration(seconds: 15))
                      .millisecondsSinceEpoch /
                  1000,
              'safety': 'advisory_only',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await service.pair('pairing-code');
      await service.chat('xin chào', {'status': 'idle'});
      expect(requests.last.url.host, 'backend.example');
      expect(requests.last.headers['Authorization'], 'Bearer device-token');
      expect(requests.last.body, isNot(contains('device-token')));
      expect(credentials.record!['token'], 'device-token');
      service.dispose();
    },
  );
  test(
    'unencrypted public endpoint is refused before a network request',
    () async {
      var networkCalls = 0;
      final service = AiAssistantService(
        credentials: MemoryCredentials(),
        serverUrl: () => 'http://public.example',
        clientFactory: () => MockClient((_) async {
          networkCalls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.pair('code', allowInsecure: true),
        throwsA(isA<AssistantException>()),
      );
      expect(networkCalls, 0);
    },
  );
  test(
    'unsupported or automatically approved actions cannot enter the app',
    () {
      expect(
        () => AssistantProposal.fromJson({
          'action': 'walk_forward',
          'requires_confirmation': true,
        }),
        throwsFormatException,
      );
      expect(
        () => AssistantProposal.fromJson({
          'action': 'cancel_navigation',
          'requires_confirmation': false,
        }),
        throwsFormatException,
      );
    },
  );
  test('context becomes stale after movement, route change or pause', () {
    final now = DateTime.now();
    const before = RouteProgress(
      status: NavigationStatus.navigating,
      position: GeoPoint(21, 105),
    );
    const after = RouteProgress(
      status: NavigationStatus.navigating,
      position: GeoPoint(21.001, 105),
    );
    expect(
      AssistantProactivityPolicy.contextStillCurrent(before, after, now, now),
      false,
    );
    expect(
      AssistantProactivityPolicy.contextStillCurrent(
        before,
        const RouteProgress(status: NavigationStatus.paused),
        now,
        now,
      ),
      false,
    );
    expect(
      AssistantProactivityPolicy.contextStillCurrent(
        before,
        before,
        now.subtract(const Duration(seconds: 40)),
        now,
      ),
      false,
    );
  });
  test('proactive events are deduplicated and have a shared cooldown', () {
    final policy = AssistantProactivityPolicy(), now = DateTime.now();
    const error = RouteProgress(
      status: NavigationStatus.error,
      message: 'Mất kết nối',
    );
    expect(policy.candidate(error, now), 'error');
    expect(
      policy.candidate(
        const RouteProgress(status: NavigationStatus.poorGps),
        now.add(const Duration(seconds: 60)),
      ),
      isNull,
    );
    expect(
      policy.candidate(error, now.add(const Duration(minutes: 3))),
      isNull,
    );
    expect(
      policy.candidate(
        const RouteProgress(status: NavigationStatus.navigating),
        now.add(const Duration(minutes: 5)),
      ),
      isNull,
    );
  });

  late FakeAssistant service;
  late AssistantController controller;
  late RouteProgress current;
  late List<String> actions, spoken;
  late bool canSpeak;
  void setupController() {
    service = FakeAssistant();
    current = const RouteProgress(
      status: NavigationStatus.navigating,
      position: GeoPoint(21, 105),
    );
    actions = [];
    spoken = [];
    canSpeak = true;
    controller = AssistantController(
      service: service,
      snapshot: () => current,
      detections: () => [],
      yoloUpdatedAt: () => null,
      captureImage: () => throw const AssistantException('no camera'),
      onConfirmed: (proposal) async {
        actions.add(proposal.action);
      },
      speak: (text) async {
        spoken.add(text);
        return true;
      },
      canSpeak: () => canSpeak,
      canProactivelyRequest: () => true,
    );
  }

  test(
    'destination proposal does not execute until the user confirms',
    () async {
      setupController();
      service.reply = AssistantReply(
        requestId: 'test',
        text: 'Đã tìm địa điểm, chờ xác nhận',
        expiresAt: DateTime.now().add(const Duration(seconds: 15)),
        proposals: [
          AssistantProposal(
            id: 'proposal',
            action: 'set_destination',
            expiresAt: DateTime.now().add(const Duration(seconds: 45)),
            place: const Placemark(
              lat: 21.1,
              lng: 105.1,
              displayName: 'Công viên',
            ),
          ),
        ],
      );
      await controller.ask('Tìm công viên');
      expect(actions, isEmpty);
      expect(controller.state.proposal, isNotNull);
      await controller.confirmProposal();
      expect(actions, ['set_destination']);
      await controller.dispose();
    },
  );
  test('stale reply cannot speak or create a navigation proposal', () async {
    setupController();
    service.pending = Completer<AssistantReply>();
    final asking = controller.ask('Tôi ở đâu?');
    current = const RouteProgress(
      status: NavigationStatus.navigating,
      position: GeoPoint(21.001, 105),
    );
    service.pending!.complete(
      AssistantReply(
        requestId: 'test',
        text: 'Thông tin cũ',
        expiresAt: DateTime.now().add(const Duration(seconds: 15)),
      ),
    );
    await asking;
    expect(spoken.where((text) => text.contains('Thông tin cũ')), isEmpty);
    expect(controller.state.messages.where((m) => !m.fromUser), isEmpty);
    expect(controller.state.error, contains('thay đổi'));
    await controller.dispose();
  });
  test(
    'obstacle speech priority blocks AI speech but preserves its displayed answer',
    () async {
      setupController();
      canSpeak = false;
      await controller.ask('Mô tả ngữ cảnh');
      expect(spoken, isEmpty);
      expect(controller.state.messages.last.fromUser, false);
      expect(actions, isEmpty);
      await controller.dispose();
    },
  );
  test('disabled AI does not execute navigation callbacks', () async {
    setupController();
    service.enabled = false;
    await controller.ask('Hỏi trợ lý');
    expect(service.calls, 0);
    expect(actions, isEmpty);
    expect(controller.state.error, contains('Dẫn đường vẫn hoạt động'));
    await controller.dispose();
  });
}
