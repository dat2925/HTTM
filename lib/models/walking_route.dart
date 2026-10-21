import 'geo_point.dart';
import 'waypoint.dart';

class WalkingRoute {
  WalkingRoute({required this.geometry, required this.waypoints}) {
    if (geometry.length < 2 || waypoints.isEmpty) {
      throw const FormatException('Empty route');
    }
    var previous = 0;
    for (final waypoint in waypoints) {
      if (waypoint.shapeIndex < previous ||
          waypoint.shapeIndex >= geometry.length) {
        throw const FormatException('Invalid maneuver index');
      }
      previous = waypoint.shapeIndex;
    }
    cumulativeMeters = [0];
    for (var i = 1; i < geometry.length; i++) {
      cumulativeMeters.add(
        cumulativeMeters.last + geometry[i - 1].distanceTo(geometry[i]),
      );
    }
  }
  final List<GeoPoint> geometry;
  final List<Waypoint> waypoints;
  late final List<double> cumulativeMeters;
  double get lengthMeters => cumulativeMeters.last;
  factory WalkingRoute.fromJson(Map<String, dynamic> json) {
    if (json['profile'] != 'pedestrian') {
      throw const FormatException('Pedestrian route required');
    }
    return WalkingRoute(
      geometry: (json['geometry'] as List)
          .map((point) => GeoPoint.fromJson(point as List))
          .toList(),
      waypoints: (json['waypoints'] as List)
          .map((point) => Waypoint.fromJson(Map<String, dynamic>.from(point)))
          .toList(),
    );
  }
}
