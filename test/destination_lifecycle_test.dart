import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/controllers/session_controller.dart';
import 'package:smart_navigation/models/placemark.dart';
import 'package:smart_navigation/screens/home_screen.dart';
import 'package:smart_navigation/services/geocoding_service.dart';

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
}
