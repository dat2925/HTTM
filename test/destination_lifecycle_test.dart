import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_navigation/config/ai_config.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/placemark.dart';
import 'package:smart_navigation/screens/home_screen.dart';
import 'package:smart_navigation/services/geocoding_service.dart';
import 'package:smart_navigation/services/route_service.dart';

import 'assistant_test.dart' show FakeAssistant;
import 'session_navigation_test.dart' show FakeRoute;
import 'support/device_fakes.dart';

const place = Placemark(lat: 21, lng: 105, displayName: 'Old destination');

class PendingGeocoder extends GeocodingService {
  final reply = Completer<Placemark>();
  @override
  Future<Placemark> search(String query, {double? nearLat, double? nearLng}) =>
      reply.future;
}

class SearchPreviewSession extends SessionController {
  SearchPreviewSession(this.geocoder)
    : super(
        routeService: FakeRoute(),
        ttsService: RecordingTts(),
        frameSource: FakeCamera(),
        voiceService: FakeVoice(),
        assistantService: FakeAssistant(),
      );
  final PendingGeocoder geocoder;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> start() async => false;
  @override
  Future<void> pauseNavigation() async {}
  @override
  Future<void> resumeNavigation() async {}
  @override
  Future<Placemark> findDestination(String query) => geocoder.search(query);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final resume in [false, true]) {
    test('pause rejects old spoken destination, resume=$resume', () async {
      final geocoder = PendingGeocoder(),
          tts = RecordingTts(),
          route = FakeRoute();
      final session = SessionController(
        geocodingService: geocoder,
        ttsService: tts,
        routeService: route,
        frameSource: FakeCamera(),
        voiceService: FakeVoice(),
        assistantService: FakeAssistant(),
      );
      addTearDown(session.dispose);
      final searching = session.handleUtterance('đi đến công viên');
      await session.pauseNavigation();
      if (resume) await session.resumeNavigation();
      geocoder.reply.complete(place);
      await searching;
      expect(session.pendingDestination, isNull);
      expect(route.destinations, 0);
      expect(tts.spoken, isEmpty);
    });
  }

  test('old geocoding failure is not spoken after pause and resume', () async {
    final geocoder = PendingGeocoder(), tts = RecordingTts();
    final session = SessionController(
      geocodingService: geocoder,
      ttsService: tts,
      routeService: FakeRoute(),
      frameSource: FakeCamera(),
      voiceService: FakeVoice(),
      assistantService: FakeAssistant(),
    );
    addTearDown(session.dispose);
    final searching = session.handleUtterance('đi đến công viên');
    await session.pauseNavigation();
    await session.resumeNavigation();
    geocoder.reply.completeError(const GeocodingException('old error'));
    await searching;
    expect(tts.spoken, isEmpty);
  });

  testWidgets(
    'typed destination cannot open an old confirmation after resume',
    (tester) async {
      final geocoder = PendingGeocoder();
      final session = SearchPreviewSession(geocoder);
      await tester.pumpWidget(
        MaterialApp(home: HomeScreen(controller: session)),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'công viên');
      await tester.tap(find.byTooltip('Tìm địa điểm'));
      await tester.pump();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      geocoder.reply.complete(place);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Old destination'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(session.dispose);
    },
  );

  test(
    'pending destination expires after 30s and allows urgent route instructions',
    () => fakeAsync((async) {
      final geocoder = PendingGeocoder(),
          tts = RecordingTts(),
          route = FakeRoute();
      final session = SessionController(
        geocodingService: geocoder,
        ttsService: tts,
        routeService: route,
        frameSource: FakeCamera(),
        voiceService: FakeVoice(),
        assistantService: FakeAssistant(),
      );
      session.initialize();
      async.flushMicrotasks();
      session.handleUtterance('đi đến công viên');
      geocoder.reply.complete(place);
      async.flushMicrotasks();
      expect(session.pendingDestination, isNotNull);

      // Normal route instruction is blocked while destination confirmation is pending.
      route.events.add(
        const RouteInstruction(text: 'Đi thẳng 50 mét', key: 'normal'),
      );
      async.flushMicrotasks();
      expect(tts.spoken.any((s) => s.$1 == 'Đi thẳng 50 mét'), isFalse);

      // Urgent route instruction (offRoute / poorGps / error) is NOT blocked.
      route.events.add(
        const RouteInstruction(
          text: 'Bạn đang lệch tuyến.',
          key: 'offRoute',
          urgent: true,
        ),
      );
      async.flushMicrotasks();
      expect(tts.spoken.any((s) => s.$1 == 'Bạn đang lệch tuyến.'), isTrue);

      // After 30s without confirmation, pending destination is cleared and announced.
      async.elapse(AiConfig.destinationConfirmTimeout);
      expect(session.pendingDestination, isNull);
      expect(
        tts.spoken.any(
          (s) => s.$1 == 'Đã hủy chọn điểm đến vì không có xác nhận.',
        ),
        isTrue,
      );
      session.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'an unrelated utterance does not keep a pending destination alive',
    () => fakeAsync((async) {
      final geocoder = PendingGeocoder(), tts = RecordingTts();
      final session = SessionController(
        geocodingService: geocoder,
        ttsService: tts,
        routeService: FakeRoute(),
        frameSource: FakeCamera(),
        voiceService: FakeVoice(),
        assistantService: FakeAssistant(),
      );
      session.initialize();
      async.flushMicrotasks();
      session.handleUtterance('đi đến công viên');
      geocoder.reply.complete(place);
      async.flushMicrotasks();
      expect(session.pendingDestination, isNotNull);

      session.handleUtterance('nhắc lại');
      async.flushMicrotasks();
      async.elapse(AiConfig.destinationConfirmTimeout);
      expect(session.pendingDestination, isNull);
      expect(
        tts.spoken.any(
          (s) => s.$1 == 'Đã hủy chọn điểm đến vì không có xác nhận.',
        ),
        isTrue,
      );
      session.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'confirming or canceling pending destination cancels the 30s expiry timer',
    () => fakeAsync((async) {
      final geocoder = PendingGeocoder(),
          tts = RecordingTts(),
          route = FakeRoute();
      final session = SessionController(
        geocodingService: geocoder,
        ttsService: tts,
        routeService: route,
        frameSource: FakeCamera(),
        voiceService: FakeVoice(),
        assistantService: FakeAssistant(),
      );
      session.initialize();
      async.flushMicrotasks();
      session.handleUtterance('đi đến công viên');
      geocoder.reply.complete(place);
      async.flushMicrotasks();
      session.confirmPendingDestination();
      async.flushMicrotasks();
      async.elapse(AiConfig.destinationConfirmTimeout);
      expect(
        tts.spoken.any(
          (s) => s.$1 == 'Đã hủy chọn điểm đến vì không có xác nhận.',
        ),
        isFalse,
      );
      session.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'GeocodingService distinguishes HTTP 404 from 502 and network errors',
    () async {
      dotenv.loadFromString(envString: 'AI_SERVER_URL=https://backend.example');
      final notFound = GeocodingService(
        client: MockClient((_) async => http.Response('{"detail":"none"}', 404)),
      );
      addTearDown(notFound.dispose);
      await expectLater(
        notFound.search('Hồ Gươm'),
        throwsA(
          isA<GeocodingException>().having(
            (e) => e.message,
            'message',
            'Không tìm thấy địa điểm "Hồ Gươm".',
          ),
        ),
      );

      final badGateway = GeocodingService(
        client: MockClient((_) async => http.Response('upstream error', 502)),
      );
      addTearDown(badGateway.dispose);
      await expectLater(
        badGateway.search('Hồ Gươm'),
        throwsA(
          isA<GeocodingException>().having(
            (e) => e.message,
            'message',
            'Không kết nối được dịch vụ tìm địa điểm.',
          ),
        ),
      );

      final networkError = GeocodingService(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      addTearDown(networkError.dispose);
      await expectLater(
        networkError.search('Hồ Gươm'),
        throwsA(
          isA<GeocodingException>().having(
            (e) => e.message,
            'message',
            'Không kết nối được dịch vụ tìm địa điểm.',
          ),
        ),
      );
    },
  );
}
