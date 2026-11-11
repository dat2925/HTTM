import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/models/walking_route.dart';
import 'package:smart_navigation/models/waypoint.dart';
import 'package:smart_navigation/services/compass_service.dart';
import 'package:smart_navigation/services/journey_store.dart';
import 'package:smart_navigation/services/location_source.dart';
import 'package:smart_navigation/services/route_planning_service.dart';
import 'package:smart_navigation/services/route_service.dart';

import 'route_tracker_test.dart' show path;

class MemoryStore extends JourneyStore {
  JourneyRecord record = const JourneyRecord();
  @override
  Future<JourneyRecord> load() async => record;
  @override
  Future<void> save(JourneyRecord record) async {
    this.record = record;
  }
}

class FakeLocation extends LocationSource {
  FakeLocation(this.latest);
  NavigationFix latest;
  final events = StreamController<NavigationFix>.broadcast(sync: true);
  @override
  Future<void> ensureAvailable() async {}
  @override
  Stream<NavigationFix> get fixes => events.stream;
  @override
  Future<NavigationFix> current() async => latest;
  void add(NavigationFix fix) {
    latest = fix;
    events.add(fix);
  }
}

class FakeCompass extends CompassService {
  final events = StreamController<double>.broadcast(sync: true);
  @override
  Stream<double> get heading => events.stream;
}

class FakePlanner extends RoutePlanningService {
  final requests = <GeoPoint>[];
  Future<WalkingRoute> Function(GeoPoint from, GeoPoint to)? handler;
  @override
  Future<WalkingRoute> plan({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) {
    final from = GeoPoint(fromLat, fromLng), to = GeoPoint(toLat, toLng);
    requests.add(to);
    return handler?.call(from, to) ?? Future.value(path([from, to]));
  }
}

void main() {
  late DateTime now;
  late FakeLocation location;
  late FakeCompass compass;
  late FakePlanner planner;
  late MemoryStore store;
  late PedestrianRouteService service;
  NavigationFix fix(
    double lng, {
    double lat = 0,
    double accuracy = 4,
    double speed = 1,
  }) => NavigationFix(
    point: GeoPoint(lat, lng),
    accuracy: accuracy,
    timestamp: now,
    speed: speed,
  );
  setUp(() {
    now = DateTime(2026, 10, 14, 10);
    location = FakeLocation(fix(0));
    compass = FakeCompass();
    planner = FakePlanner();
    store = MemoryStore();
    service = PedestrianRouteService(
      locationSource: location,
      compassService: compass,
      planningService: planner,
      journeyStore: store,
      now: () => now,
      checkInterval: const Duration(milliseconds: 20),
    );
  });
  tearDown(() async {
    await service.dispose();
    await location.events.close();
    await compass.events.close();
  });

  test('GPS location exists before selecting any destination', () async {
    await service.start();
    expect(service.snapshot.position, isNotNull);
    expect(service.snapshot.status, NavigationStatus.idle);
    expect(planner.requests, isEmpty);
  });
  test(
    'start includes first instruction and is not repeated on refresh',
    () async {
      final events = <RouteInstruction>[];
      final subscription = service.instructions.listen(events.add);
      await service.start();
      await service.setDestination(0, .001, name: 'Công viên');
      await service.refresh();
      await Future<void>.delayed(Duration.zero);
      final starts = events
          .where((e) => e.key.startsWith('journey-start:'))
          .toList();
      expect(starts, hasLength(1));
      expect(starts.single.text, contains('Công viên'));
      expect(starts.single.text, contains('Đi tiếp'));
      expect(starts.single.once, isTrue);
      await subscription.cancel();
    },
  );

  for (final side in ['trái', 'phải']) {
    test('announces approaching and crossing a $side turn once', () async {
      planner.handler = (_, _) async => WalkingRoute(
        geometry: const [
          GeoPoint(0, 0),
          GeoPoint(0, .0002),
          GeoPoint(.001, .0002),
        ],
        waypoints: [
          const Waypoint(
            lat: 0,
            lng: 0,
            distanceMeters: 0,
            instruction: 'Đi tiếp',
          ),
          Waypoint(
            lat: 0,
            lng: .0002,
            distanceMeters: 0,
            shapeIndex: 1,
            instruction: 'Rẽ $side',
          ),
          const Waypoint(
            lat: .001,
            lng: .0002,
            distanceMeters: 0,
            shapeIndex: 2,
            type: 'arrive',
            instruction: 'Đã đến nơi',
          ),
        ],
      );
      final events = <RouteInstruction>[];
      final subscription = service.instructions.listen(events.add);
      await service.start();
      compass.events.add(90);
      await service.setDestination(.001, .0002);
      expect(
        service.snapshot.message,
        endsWith('Đi thẳng 22 mét, rồi rẽ $side.'),
      );
      now = now.add(const Duration(seconds: 5));
      location.add(fix(.0001));
      now = now.add(const Duration(seconds: 5));
      location.add(fix(.0002, lat: .00002));
      now = now.add(const Duration(seconds: 1));
      location.add(fix(.0002, lat: .00003));
      await Future<void>.delayed(Duration.zero);
      expect(
        events.any(
          (e) => e.text.contains('Sau') && e.text.contains('rẽ $side'),
        ),
        isTrue,
      );
      final reached = events.where((e) => e.key.endsWith(':turn-now')).toList();
      expect(reached, hasLength(1));
      expect(reached.single.text, contains('rẽ $side'));
      expect(reached.single.once, isTrue);
      await subscription.cancel();
    });
  }

  test('fresh compass wins over GPS course including poor GPS', () async {
    await service.start();
    await service.setDestination(0, .001);
    compass.events.add(270);
    now = now.add(const Duration(seconds: 5));
    location.add(fix(.0001));
    expect(service.snapshot.message, contains('Quay lại'));
    compass.events.add(180);
    expect(service.snapshot.message, contains('Quay lại'));
    now = now.add(const Duration(seconds: 1));
    location.add(fix(.00011, accuracy: 80));
    expect(service.snapshot.status, NavigationStatus.poorGps);
    now = now.add(const Duration(seconds: 1));
    location.add(fix(.00012));
    expect(service.snapshot.message, contains('Quay lại'));
  });
  for (final (heading, instruction) in [
    (90.0, 'Đi thẳng. Còn 111 mét tới đích.'),
    (130.0, 'Chếch sang trái, hướng 11 giờ.'),
    (50.0, 'Chếch sang phải, hướng 1 giờ.'),
    (180.0, 'Quay sang trái, hướng 9 giờ.'),
    (0.0, 'Quay sang phải, hướng 3 giờ.'),
    (270.0, 'Quay lại.'),
  ]) {
    test('stationary compass $heading gives $instruction', () async {
      location.latest = fix(0, speed: 0);
      await service.start();
      compass.events.add(heading);
      await service.setDestination(0, .001);
      expect(service.snapshot.message, endsWith(instruction));
      now = now.add(const Duration(seconds: 1));
      location.add(fix(0, speed: 0));
      expect(service.snapshot.message, instruction);
    });
  }

  test('hysteresis holds around 25 degrees and resets with route', () async {
    await service.start();
    compass.events.add(66); // 24 degrees to the right of the phone.
    await service.setDestination(0, .001);
    void face(double heading) {
      final current = service.snapshot.headingDegrees!;
      now = now.add(const Duration(seconds: 1));
      compass.events.add(current + 4 * (heading - current));
    }

    for (final delta in [26.0, 24.0, 32.0]) {
      face(90 - delta);
      expect(service.snapshot.message, startsWith('Đi thẳng'));
    }
    face(56); // 34 > 25 + 8.
    expect(service.snapshot.message, startsWith('Chếch sang phải, hướng'));
    for (final delta in [26.0, 24.0, 18.0]) {
      face(90 - delta);
      expect(service.snapshot.message, startsWith('Chếch sang phải, hướng'));
    }
    await service.refresh(); // Fresh route resets hysteresis at 18 degrees.
    expect(service.snapshot.message, startsWith('Đúng hướng. Đi thẳng'));
    face(56);
    face(74); // 16 < 25 - 8.
    expect(service.snapshot.message, contains('Đi thẳng'));
    face(56);
    face(64); // Hold slight right at 26 degrees.
    await service.setDestination(0, .002);
    expect(service.snapshot.message, contains('Chếch sang phải, hướng'));
  });

  test(
    '40m GPS guides; 80m retains match and warns once per weak episode',
    () async {
      location.latest = fix(0, accuracy: 40);
      final events = <RouteInstruction>[];
      final subscription = service.instructions.listen(events.add);
      await service.start();
      compass.events.add(0);
      expect(await service.setDestination(0, .001), isTrue);
      expect(
        service.snapshot.message,
        contains('Quay sang phải, hướng 3 giờ.'),
      );
      final matched = service.snapshot.remainingPath.first;
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 1));
        location.add(fix(.0005, accuracy: 80));
        expect(service.snapshot.message, 'Quay sang phải, hướng 3 giờ.');
        expect(service.snapshot.remainingPath.first, matched);
      }
      await Future<void>.delayed(Duration.zero);
      var warnings = events
          .where((e) => e.key.startsWith('weak-gps:'))
          .toList();
      expect(warnings, hasLength(1));
      expect(warnings.single.once, isTrue);
      expect(warnings.single.text, 'GPS yếu, chỉ hướng có thể kém chính xác.');
      now = now.add(const Duration(seconds: 1));
      location.add(fix(0, accuracy: 40));
      now = now.add(const Duration(seconds: 1));
      location.add(fix(0, accuracy: 80));
      await Future<void>.delayed(Duration.zero);
      warnings = events.where((e) => e.key.startsWith('weak-gps:')).toList();
      expect(warnings, hasLength(2));
      expect(warnings.first.key, isNot(warnings.last.key));
      await subscription.cancel();
    },
  );

  test('idle is a fixed once event', () async {
    final events = <RouteInstruction>[];
    final subscription = service.instructions.listen(events.add);
    await service.start();
    compass.events.add(90);
    await Future<void>.delayed(Duration.zero);
    final idle = events.where((e) => e.key == 'idle-ready');
    expect(idle.length, greaterThanOrEqualTo(2));
    expect(idle.every((e) => e.once), isTrue);
    await subscription.cancel();
  });

  test('stale GPS keeps compass guidance with the last match', () async {
    final events = <RouteInstruction>[];
    final subscription = service.instructions.listen(events.add);
    await service.start();
    await service.setDestination(0, .001);
    now = now.add(const Duration(seconds: 31));
    compass.events.add(0);
    expect(service.snapshot.message, 'Quay sang phải, hướng 3 giờ.');
    compass.events.add(0);
    await service.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(events.where((e) => e.key.startsWith('weak-gps:')), hasLength(1));
    expect(planner.requests, hasLength(1));
    await subscription.cancel();
  });

  for (final (accuracy, longitude) in [(40.0, .0008), (4.0, .00094)]) {
    test('arrival tolerance for accuracy $accuracy needs two fixes', () async {
      await service.start();
      await service.setDestination(0, .001);
      now = now.add(const Duration(seconds: 30));
      location.add(fix(longitude, accuracy: accuracy));
      expect(service.snapshot.status, isNot(NavigationStatus.arrived));
      now = now.add(const Duration(seconds: 1));
      location.add(fix(longitude, accuracy: accuracy));
      expect(service.snapshot.status, NavigationStatus.arrived);
    });
  }

  test(
    'expired compass falls back to fresh GPS course then no heading',
    () async {
      await service.start();
      compass.events.add(270);
      await service.setDestination(0, .001);
      now = now.add(const Duration(seconds: 5));
      location.add(fix(.0001));
      expect(service.snapshot.message, 'Quay lại.');
      now = now.add(const Duration(seconds: 6));
      location.add(fix(.0002));
      expect(service.snapshot.headingDegrees, isNull);
      expect(service.snapshot.message, startsWith('Đúng hướng. Đi thẳng'));
      now = now.add(const Duration(seconds: 1));
      location.add(fix(.00021, accuracy: 20));
      expect(service.snapshot.message, startsWith('Đi tiếp theo tuyến.'));
    },
  );

  test(
    'retained route keeps the heading action first after refresh failure',
    () async {
      await service.start();
      compass.events.add(0);
      await service.setDestination(0, .001);
      planner.handler = (_, _) =>
          Future.error(const RoutePlanningException('offline'));
      await service.refresh();
      now = now.add(const Duration(seconds: 1));
      compass.events.add(0);
      expect(service.snapshot.status, NavigationStatus.error);
      expect(service.snapshot.message, 'Quay sang phải, hướng 3 giờ.');
    },
  );

  test('new destination wins when older request finishes last', () async {
    await service.start();
    final old = Completer<WalkingRoute>();
    planner.handler = (from, to) =>
        to.lng == .001 ? old.future : Future.value(path([from, to]));
    final first = service.setDestination(0, .001, name: 'Cũ');
    await service.setDestination(0, .002, name: 'Mới');
    old.complete(path([const GeoPoint(0, 0), const GeoPoint(0, .001)]));
    await first;
    expect(service.snapshot.destinationName, 'Mới');
    expect(service.snapshot.remainingPath.last.lng, .002);
  });
  test('failed destination cannot continue previous route', () async {
    await service.start();
    await service.setDestination(0, .001);
    planner.handler = (_, _) =>
        Future.error(const RoutePlanningException('offline'));
    expect(await service.setDestination(0, .002), false);
    expect(service.snapshot.status, NavigationStatus.error);
    expect(service.snapshot.remainingPath, isEmpty);
    expect(service.snapshot.destination!.lng, .002);
  });
  test('fresh phone heading overrides reliable reverse movement', () async {
    await service.start();
    await service.setDestination(0, .001);
    now = now.add(const Duration(seconds: 5));
    location.add(fix(.0001));
    now = now.add(const Duration(seconds: 5));
    location.add(fix(0));
    expect(service.snapshot.message, contains('Quay lại'));
    compass.events.add(90);
    expect(service.snapshot.message, contains('Đi thẳng'));
    now = now.add(const Duration(seconds: 1));
    location.add(fix(.00001, accuracy: 20));
    expect(service.snapshot.message, contains('Đi thẳng'));
  });
  test('poor GPS cannot complete the journey', () async {
    await service.start();
    await service.setDestination(0, .001);
    for (var i = 0; i < 4; i++) {
      now = now.add(const Duration(seconds: 1));
      location.add(fix(.001, accuracy: 80));
    }
    expect(service.snapshot.status, NavigationStatus.poorGps);
  });
  test('arrival requires two good GPS fixes and endpoint distance', () async {
    await service.start();
    await service.setDestination(0, .0001);
    now = now.add(const Duration(seconds: 1));
    location.add(fix(.0001));
    expect(service.snapshot.status, isNot(NavigationStatus.arrived));
    now = now.add(const Duration(seconds: 1));
    location.add(fix(.0001));
    expect(service.snapshot.status, NavigationStatus.arrived);
  });
  test('rerouting preserves actual walked trail and distance', () async {
    await service.start();
    await service.setDestination(0, .001);
    now = now.add(const Duration(seconds: 10));
    location.add(fix(.0001));
    final walked = service.snapshot.walkedMeters;
    final count = service.snapshot.walkedPath.length;
    await service.refresh();
    expect(service.snapshot.walkedMeters, walked);
    expect(service.snapshot.walkedPath.length, count);
    expect(walked, greaterThan(10));
    expect(store.record.points.length, count);
  });
  test('pause invalidates pending route response', () async {
    await service.start();
    final result = Completer<WalkingRoute>();
    planner.handler = (_, _) => result.future;
    final planning = service.setDestination(0, .001);
    service.stop();
    result.complete(path([const GeoPoint(0, 0), const GeoPoint(0, .001)]));
    expect(await planning, false);
    expect(service.snapshot.status, NavigationStatus.paused);
  });
  test(
    'confirmed deviation triggers a route from the actual location',
    () async {
      await service.start();
      await service.setDestination(0, .001);
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 10));
        location.add(fix(.0001, lat: .0002));
      }
      await service.progress
          .firstWhere((p) => p.lastRouteUpdate == now)
          .timeout(const Duration(seconds: 2));
      expect(planner.requests.length, 2);
      expect(service.snapshot.remainingPath.first.lat, closeTo(.0002, .000001));
    },
  );
  test('restored trail does not join across the app restart', () async {
    store.record = const JourneyRecord(
      points: [GeoPoint(0, -.001), GeoPoint(0, -.0009)],
      walkedMeters: 11,
    );
    await service.start();
    expect(service.snapshot.walkedMeters, 11);
    expect(service.snapshot.trailBreakIndices, [2]);
    expect(service.snapshot.walkedPath.length, 3);
  });
  test('compass smooths across north and old GPS events are ignored', () async {
    await service.start();
    compass.events.add(359);
    now = now.add(const Duration(seconds: 2));
    compass.events.add(1);
    final heading = service.snapshot.headingDegrees!;
    expect(heading > 350 || heading < 10, isTrue);
    final before = service.snapshot.position;
    location.add(
      NavigationFix(
        point: const GeoPoint(0, .001),
        accuracy: 4,
        timestamp: now.subtract(const Duration(seconds: 10)),
      ),
    );
    expect(service.snapshot.position, same(before));
  });
  test('periodic replanning refreshes route from current GPS', () async {
    await service.start();
    await service.setDestination(0, .001);
    now = now.add(const Duration(seconds: 31));
    location.add(fix(.0001));
    await service.progress
        .firstWhere((p) => p.lastRouteUpdate == now)
        .timeout(const Duration(seconds: 2));
    expect(planner.requests.length, 2);
    expect(service.snapshot.remainingPath.first.lng, closeTo(.0001, .000001));
  });
}
