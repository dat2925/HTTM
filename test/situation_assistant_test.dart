import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/assistant_controller.dart';
import 'package:smart_navigation/models/assistant_state.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/situation_context.dart';
import 'package:smart_navigation/services/assistant_policy.dart';
import 'package:smart_navigation/services/assistant_service.dart';
import 'package:smart_navigation/services/situation_engine.dart';
import 'assistant_context_test.dart' show ContextAssistant;
import 'support/device_fakes.dart';

class EventAssistant extends ContextAssistant {
  final events = <String?>[];
  @override
  Future<AssistantReply> chat(
    String message,
    Map<String, dynamic> context, {
    dynamic image,
    bool proactive = false,
    String? event,
  }) {
    events.add(event);
    return super.chat(
      message,
      context,
      image: image,
      proactive: proactive,
      event: event,
    );
  }

  @override
  Future<void> setProactive(bool enabled) async {
    proactiveEnabled = enabled;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('event priority, expiry, deduplication and shared cooldown', () {
    final policy = AssistantProactivityPolicy(), engine = SituationEngine();
    final now = DateTime.now();
    final base = engine.snapshot(
      const RouteProgress(status: NavigationStatus.idle),
      now,
    );
    SituationEvent event(String kind, int priority, {int ttl = 20}) =>
        SituationEvent(
          kind: kind,
          key: kind,
          priority: priority,
          createdAt: now,
          expiresAt: now.add(Duration(seconds: ttl)),
        );
    SituationContext context(List<SituationEvent> events) => SituationContext(
      timestamp: now,
      revision: 1,
      navigation: base.navigation,
      detections: [],
      sourceFreshness: base.sourceFreshness,
      observations: [],
      uncertainty: [],
      events: events,
    );
    final events = context([
      event('routeChanged', 1),
      event('obstacle', 2),
      event('sensorLost', 3, ttl: -1),
    ]);
    expect(policy.candidateSituation(events, now)!.kind, 'obstacle');
    expect(
      policy.candidateSituation(events, now.add(const Duration(seconds: 1))),
      isNull,
    );
    final repeated = context([
      SituationEvent(
        kind: 'obstacle',
        key: 'obstacle',
        priority: 2,
        createdAt: now,
        expiresAt: now.add(const Duration(minutes: 5)),
      ),
    ]);
    expect(
      policy.candidateSituation(repeated, now.add(const Duration(minutes: 3))),
      isNull,
    );
  });

  test(
    'proactive stable obstacle makes one request and never uploads images',
    () async {
      final ai = EventAssistant()..proactiveEnabled = true;
      final engine = SituationEngine(), now = DateTime.now();
      final latest = now.subtract(const Duration(milliseconds: 100));
      engine.observeDetections(
        dangerDetection.objects,
        latest.subtract(const Duration(seconds: 1)),
        now,
      );
      engine.observeDetections(dangerDetection.objects, latest, now);
      final controller = AssistantController(
        service: ai,
        snapshot: () => const RouteProgress(status: NavigationStatus.idle),
        detections: () => dangerDetection.objects,
        yoloUpdatedAt: () => latest,
        situationEngine: engine,
        captureImage: () => throw StateError('No proactive capture'),
        onConfirmed: (_) async => fail('No mutation'),
        speak: (_) async => true,
        canSpeak: () => true,
        canProactivelyRequest: () => true,
      );
      addTearDown(controller.dispose);
      await controller.checkProactive();
      await controller.checkProactive();
      expect(ai.calls, 1);
      expect(ai.events, ['obstacle']);
      expect(ai.image, isNull);
    },
  );

  test('new scene invalidates in-flight evidence and pending speech', () async {
    final ai = EventAssistant()..pending = Completer<AssistantReply>();
    var at = DateTime.now();
    var objects = dangerDetection.objects;
    final spoken = <String>[];
    final controller = AssistantController(
      service: ai,
      snapshot: () => const RouteProgress(status: NavigationStatus.idle),
      detections: () => objects,
      yoloUpdatedAt: () => at,
      captureImage: () => throw const AssistantException('No camera'),
      onConfirmed: (_) async {},
      speak: (text) async {
        spoken.add(text);
        return true;
      },
      canSpeak: () => true,
      canProactivelyRequest: () => true,
    );
    addTearDown(controller.dispose);
    final asking = controller.ask('Có gì phía trước?');
    objects = [];
    at = at.add(const Duration(milliseconds: 1));
    ai.pending!.complete(
      AssistantReply(
        requestId: 'test',
        text: 'Quan sát cũ',
        expiresAt: DateTime.now().add(const Duration(seconds: 5)),
        guidance: const AssistantGuidance(
          kind: 'observation',
          evidenceSources: ['yolo'],
          confidence: 'limited',
          priority: 2,
        ),
      ),
    );
    await asking;
    expect(spoken, isNot(contains('Quan sát cũ')));
    expect(controller.state.messages.where((m) => !m.fromUser), isEmpty);
  });

  test(
    'camera failure and expired image still allow contextual text advice',
    () async {
      final ai = EventAssistant();
      final controller = AssistantController(
        service: ai,
        snapshot: () => const RouteProgress(status: NavigationStatus.idle),
        detections: () => [],
        yoloUpdatedAt: () => null,
        captureImage: () async => AssistantImage(
          Uint8List.fromList([1, 2]),
          DateTime.now().subtract(const Duration(seconds: 20)),
        ),
        onConfirmed: (_) async {},
        speak: (_) async => true,
        canSpeak: () => true,
        canProactivelyRequest: () => true,
      );
      addTearDown(controller.dispose);
      await controller.ask('Xung quanh tôi có gì?', includeImage: true);
      expect(ai.calls, 1);
      expect(ai.image, isNull);
      expect(ai.context!['image_captured_at'], isNull);
      expect(controller.state.messages.last.fromUser, false);
    },
  );

  test('turning proactive off discards its in-flight response', () async {
    final ai = EventAssistant()..proactiveEnabled = true;
    ai.pending = Completer<AssistantReply>();
    final controller = AssistantController(
      service: ai,
      snapshot: () => const RouteProgress(status: NavigationStatus.idle),
      detections: () => [],
      yoloUpdatedAt: () => null,
      captureImage: () => throw StateError('No capture'),
      onConfirmed: (_) async {},
      speak: (_) async => true,
      canSpeak: () => true,
      canProactivelyRequest: () => true,
    );
    addTearDown(controller.dispose);
    final asking = controller.ask(
      'Giải thích',
      proactive: true,
      event: 'sensorLost',
    );
    await controller.setProactive(false);
    ai.pending!.complete(
      AssistantReply(
        requestId: 'test',
        text: 'Cũ',
        expiresAt: DateTime.now().add(const Duration(seconds: 5)),
      ),
    );
    await asking;
    expect(controller.state.messages, isEmpty);
    expect(controller.state.busy, false);
  });

  test(
    'deferred speech keeps precautions without replaying expired observations',
    () async {
      final ai = EventAssistant();
      final spoken = <String>[];
      var canSpeak = false;
      ai.reply = AssistantReply(
        requestId: 'test',
        text: 'Quan sát đã hết hạn',
        expiresAt: DateTime.now().add(const Duration(milliseconds: 100)),
        guidance: AssistantGuidance(
          kind: 'precaution',
          evidenceSources: ['user'],
          confidence: 'limited',
          priority: 1,
          recommendations: const ['Bạn nên dừng lại để kiểm tra.'],
          precautionExpiresAt: DateTime.now().add(const Duration(seconds: 15)),
        ),
      );
      final controller = AssistantController(
        service: ai,
        snapshot: () => const RouteProgress(status: NavigationStatus.idle),
        detections: () => [],
        yoloUpdatedAt: () => null,
        captureImage: () => throw StateError('No capture'),
        onConfirmed: (_) async {},
        speak: (text) async {
          spoken.add(text);
          return true;
        },
        canSpeak: () => canSpeak,
        canProactivelyRequest: () => false,
      );
      addTearDown(controller.dispose);
      await controller.ask('Tôi nên làm gì?');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      canSpeak = true;
      await controller.checkProactive();
      expect(spoken.single, startsWith('Nếu tình huống này vẫn còn:'));
      expect(spoken.single, isNot(contains('Quan sát đã hết hạn')));
      await controller.checkProactive();
      expect(spoken, hasLength(1));
    },
  );

  test(
    'ordinary knowledge remains usable when navigation updates during the request',
    () async {
      final ai = EventAssistant()..pending = Completer<AssistantReply>();
      var progress = const RouteProgress(status: NavigationStatus.locating);
      final controller = AssistantController(
        service: ai,
        snapshot: () => progress,
        detections: () => [],
        yoloUpdatedAt: () => null,
        captureImage: () => throw StateError('No capture'),
        onConfirmed: (_) async {},
        speak: (_) async => true,
        canSpeak: () => true,
        canProactivelyRequest: () => false,
      );
      addTearDown(controller.dispose);
      final asking = controller.ask('GPS hoạt động thế nào?');
      progress = const RouteProgress(
        status: NavigationStatus.idle,
        position: GeoPoint(21, 105),
      );
      ai.pending!.complete(
        AssistantReply(
          requestId: 'test',
          text: 'GPS sử dụng tín hiệu vệ tinh.',
          expiresAt: DateTime.now().add(const Duration(seconds: 15)),
          guidance: const AssistantGuidance(
            kind: 'information',
            evidenceSources: [],
            confidence: 'unknown',
            priority: 0,
          ),
        ),
      );
      await asking;
      expect(
        controller.state.messages.last.text,
        'GPS sử dụng tín hiệu vệ tinh.',
      );
      expect(controller.state.error, isNull);
    },
  );
}
