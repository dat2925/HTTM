import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/models/waypoint.dart';
import 'package:smart_navigation/services/obstacle_reasoning_service.dart';
import 'package:smart_navigation/services/situation_engine.dart';
import 'support/device_fakes.dart';

void main() {
  final now = DateTime(2026, 10, 22, 9);
  RouteProgress route({DateTime? gpsAt, double accuracy = 5}) => RouteProgress(
    status: NavigationStatus.navigating,
    position: const GeoPoint(21, 105),
    destination: const GeoPoint(21.001, 105),
    updatedAt: gpsAt ?? now,
    accuracyMeters: accuracy,
    headingDegrees: 90,
    headingUpdatedAt: now,
    waypoints: const [
      Waypoint(
        lat: 21.0001,
        lng: 105,
        distanceMeters: 50,
        instruction: 'Điểm sang đường trên bản đồ',
        type: 'crossing',
      ),
    ],
  );

  test('freshness covers future, stale GPS, image, heading and detection', () {
    final engine = SituationEngine();
    engine.observeDetections(dangerDetection.objects, now, now);
    final current = engine.snapshot(route(), now, imageAt: now);
    expect(current.sourceFreshness.values, everyElement(true));
    expect(current.toNavigationJson()['obstacles'], hasLength(1));
    final stale = engine.snapshot(
      route(),
      now.add(const Duration(seconds: 20)),
      imageAt: now,
    );
    expect(stale.detections, isEmpty);
    expect(stale.sourceFreshness.values, everyElement(false));
    expect(stale.toNavigationJson()['position'], isNull);
    expect(stale.toNavigationJson()['heading_degrees'], isNull);
    expect(stale.toNavigationJson()['next_instructions'], isEmpty);
    engine.observeDetections(
      dangerDetection.objects,
      now.add(const Duration(minutes: 1)),
      now,
    );
    expect(engine.snapshot(route(), now).detections, hasLength(1));
  });

  test(
    'scene requires two samples; stable frames do not create repeated events',
    () {
      final engine = SituationEngine();
      engine.observeDetections(dangerDetection.objects, now, now);
      expect(
        engine.snapshot(route(), now).events.where((e) => e.kind == 'obstacle'),
        isEmpty,
      );
      final later = now.add(const Duration(seconds: 1));
      engine.observeDetections(dangerDetection.objects, later, later);
      final situation = engine.snapshot(route(), later);
      final obstacle = situation.events.singleWhere(
        (e) => e.kind == 'obstacle',
      );
      expect(obstacle.priority, 2);
      engine.observeDetections(
        dangerDetection.objects,
        later.add(const Duration(seconds: 1)),
        later.add(const Duration(seconds: 1)),
      );
      expect(
        engine
            .snapshot(route(), later)
            .events
            .where((e) => e.kind == 'obstacle'),
        hasLength(1),
      );
      engine.clearPerception();
      expect(engine.snapshot(route(), later).detections, isEmpty);
    },
  );

  test(
    'GPS loss, recovery and approaching maneuver carry expiring evidence',
    () {
      final engine = SituationEngine();
      expect(
        engine.snapshot(route(), now).events.any((e) => e.kind == 'maneuver'),
        true,
      );
      final lost = engine.snapshot(
        route(accuracy: 100),
        now.add(const Duration(seconds: 1)),
      );
      expect(lost.events.any((e) => e.key == 'lost:gps'), true);
      expect(lost.events.any((e) => e.kind == 'maneuver'), false);
      final recovered = engine.snapshot(
        route(),
        now.add(const Duration(seconds: 2)),
      );
      expect(recovered.events.any((e) => e.kind == 'gpsRecovered'), true);
      expect(recovered.events.any((e) => e.key == 'lost:gps'), false);
    },
  );

  test(
    'local summaries and warnings never convert bbox size to physical distance',
    () {
      final reasoning = ObstacleReasoningService();
      final objects = [...dangerDetection.objects, ...dangerDetection.objects];
      expect(reasoning.summarize(objects).single, contains('2 người'));
      expect(reasoning.selectWarning(objects)!.text, isNot(contains('gần')));
      expect(ObstacleReasoningService.category('motorcycle'), 'vehicle');
      expect(ObstacleReasoningService.category('person'), 'person');
    },
  );

  test(
    'explicit watch is bounded, class-based and expires without new evidence',
    () {
      final engine = SituationEngine();
      engine.watch('person', now);
      engine.observeDetections(dangerDetection.objects, now, now);
      engine.observeDetections(
        dangerDetection.objects,
        now.add(const Duration(seconds: 1)),
        now.add(const Duration(seconds: 1)),
      );
      final watched = engine.snapshot(
        route(),
        now.add(const Duration(seconds: 1)),
      );
      expect(watched.events.any((e) => e.kind == 'watchMatch'), true);
      expect(watched.toNavigationJson()['watch_category'], 'person');
      expect(
        engine
            .snapshot(route(), now.add(const Duration(minutes: 3)))
            .watchCategory,
        isNull,
      );
      expect(
        engine
            .snapshot(route(), now.add(const Duration(minutes: 3)))
            .events
            .any((e) => e.kind == 'watchMatch'),
        false,
      );
    },
  );
}
