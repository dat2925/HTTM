import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/route_progress.dart';
import 'package:smart_navigation/models/walking_route.dart';
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
  NavigationFix fix(double lng, {double lat = 0, double accuracy = 4}) =>
      NavigationFix(
        point: GeoPoint(lat, lng),
        accuracy: accuracy,
        timestamp: now,
        speed: 1,
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
  test('poor GPS cannot complete the journey', () async {
    await service.start();
    await service.setDestination(0, .001);
    for (var i = 0; i < 4; i++) {
      now = now.add(const Duration(seconds: 1));
      location.add(fix(.001, accuracy: 80));
    }
    expect(service.snapshot.status, NavigationStatus.poorGps);
  });
  test('arrival requires three good GPS fixes and endpoint distance', () async {
    await service.start();
    await service.setDestination(0, .0001);
    for (var i = 0; i < 2; i++) {
      now = now.add(const Duration(seconds: 1));
      location.add(fix(.0001));
    }
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
