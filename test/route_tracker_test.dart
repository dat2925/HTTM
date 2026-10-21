import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/geo_point.dart';
import 'package:smart_navigation/models/waypoint.dart';
import 'package:smart_navigation/models/walking_route.dart';
import 'package:smart_navigation/services/route_tracker.dart';
import 'package:smart_navigation/services/route_service.dart';

WalkingRoute path(List<GeoPoint> points) => WalkingRoute(
  geometry: points,
  waypoints: [
    Waypoint(
      lat: points.first.lat,
      lng: points.first.lng,
      distanceMeters: 0,
      instruction: 'Đi tiếp',
    ),
    Waypoint(
      lat: points.last.lat,
      lng: points.last.lng,
      distanceMeters: 0,
      instruction: 'Đã đến nơi',
      shapeIndex: points.length - 1,
      type: 'arrive',
    ),
  ],
);

void main() {
  test(
    'remaining distance follows road bend instead of direct waypoint distance',
    () {
      final route = path([
        const GeoPoint(0, 0),
        const GeoPoint(0, .001),
        const GeoPoint(.001, .001),
      ]);
      final tracker = RouteTracker(route);
      final match = tracker.update(const GeoPoint(0, .0001), 4);
      expect(route.lengthMeters - match.alongMeters, closeTo(211.27, 1));
      final target = tracker.pointAt(match.alongMeters + 10);
      expect(match.point.bearingTo(target), closeTo(90, 1));
      expect(target.lat, closeTo(0, .000001));
    },
  );
  test('parallel return leg cannot skip the intervening route', () {
    final route = path([
      const GeoPoint(0, 0),
      const GeoPoint(0, .001),
      const GeoPoint(.00005, .001),
      const GeoPoint(.00005, 0),
    ]);
    final tracker = RouteTracker(route);
    final match = tracker.update(const GeoPoint(.00004, .00005), 6);
    expect(match.segment, 0);
    expect(match.alongMeters, lessThan(15));
  });
  test('a missed maneuver can be passed using along-route progress', () {
    final route = path([
      const GeoPoint(0, 0),
      const GeoPoint(0, .0001),
      const GeoPoint(0, .001),
    ]);
    final tracker = RouteTracker(route);
    tracker.update(const GeoPoint(0, 0), 3);
    final match = tracker.update(const GeoPoint(0, .0003), 3);
    expect(match.alongMeters, greaterThan(route.cumulativeMeters[1]));
    expect(tracker.remainingGeometry(match).first.lng, closeTo(.0003, .000001));
  });
  test('invalid profile and old waypoint-only response are rejected', () {
    expect(
      () => WalkingRoute.fromJson({'profile': 'driving'}),
      throwsFormatException,
    );
    expect(
      () => WalkingRoute(geometry: [const GeoPoint(0, 0)], waypoints: []),
      throwsFormatException,
    );
  });
  test('facing directions wrap correctly through north', () {
    expect(facingInstruction(359, 1), 'Đi thẳng');
    expect(facingInstruction(0, 90), 'Quay sang phải');
    expect(facingInstruction(0, 270), 'Quay sang trái');
    expect(facingInstruction(0, 180), 'Quay lại');
    expect(cardinalDirection(359), 'Bắc');
  });
}
