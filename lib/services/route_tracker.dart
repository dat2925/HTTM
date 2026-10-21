import 'dart:math' as math;
import '../models/geo_point.dart';
import '../models/walking_route.dart';

class RouteMatch {
  const RouteMatch({
    required this.point,
    required this.segment,
    required this.alongMeters,
    required this.crossTrackMeters,
  });
  final GeoPoint point;
  final int segment;
  final double alongMeters;
  final double crossTrackMeters;
}

/// Projects GPS onto the path, constraining progress to nearby route distance
/// so a crossing or parallel return leg cannot jump over a long section.
class RouteTracker {
  RouteTracker(this.route);
  final WalkingRoute route;
  RouteMatch? lastMatch;
  GeoPoint? _lastPosition;

  RouteMatch update(GeoPoint position, double accuracy) {
    final previous = lastMatch?.alongMeters ?? 0;
    final movement = _lastPosition?.distanceTo(position) ?? 0;
    final window = math.max(40.0, movement * 2 + accuracy * 2);
    RouteMatch? best;
    for (var i = 0; i < route.geometry.length - 1; i++) {
      if (route.cumulativeMeters[i] > previous + window ||
          route.cumulativeMeters[i + 1] < previous - window) {
        continue;
      }
      final a = route.geometry[i], b = route.geometry[i + 1];
      const scale = 111195.0;
      final longitudeScale = scale * math.cos(position.lat * math.pi / 180);
      final ax = (a.lng - position.lng) * longitudeScale;
      final ay = (a.lat - position.lat) * scale;
      final dx = (b.lng - a.lng) * longitudeScale;
      final dy = (b.lat - a.lat) * scale;
      final length2 = dx * dx + dy * dy;
      final t = length2 == 0
          ? 0.0
          : (-(ax * dx + ay * dy) / length2).clamp(0.0, 1.0);
      final distance = math.sqrt(
        math.pow(ax + t * dx, 2) + math.pow(ay + t * dy, 2),
      );
      final along =
          route.cumulativeMeters[i] +
          t * (route.cumulativeMeters[i + 1] - route.cumulativeMeters[i]);
      if (best == null ||
          distance < best.crossTrackMeters - 0.5 ||
          ((distance - best.crossTrackMeters).abs() < 0.5 &&
              (along - previous).abs() < (best.alongMeters - previous).abs())) {
        best = RouteMatch(
          point: GeoPoint(
            a.lat + t * (b.lat - a.lat),
            a.lng + t * (b.lng - a.lng),
          ),
          segment: i,
          alongMeters: along,
          crossTrackMeters: distance,
        );
      }
    }
    // Every valid route has at least one segment inside the initial/current window.
    final match = best ?? lastMatch!;
    _lastPosition = position;
    if (match.crossTrackMeters <= math.max(12, accuracy * 1.5)) {
      lastMatch = match;
    }
    return match;
  }

  GeoPoint pointAt(double meters) {
    final distance = meters.clamp(0.0, route.lengthMeters);
    for (var i = 0; i < route.geometry.length - 1; i++) {
      if (route.cumulativeMeters[i + 1] < distance) continue;
      final length = route.cumulativeMeters[i + 1] - route.cumulativeMeters[i];
      final t = length == 0
          ? 0.0
          : (distance - route.cumulativeMeters[i]) / length;
      final a = route.geometry[i], b = route.geometry[i + 1];
      return GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
    }
    return route.geometry.last;
  }

  List<GeoPoint> remainingGeometry(RouteMatch match) => [
    match.point,
    ...route.geometry.skip(match.segment + 1),
  ];
}
