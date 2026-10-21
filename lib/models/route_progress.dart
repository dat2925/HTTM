import 'geo_point.dart';
import 'waypoint.dart';

enum NavigationStatus {
  locating,
  idle,
  planning,
  navigating,
  offRoute,
  poorGps,
  arrived,
  error,
  paused,
}

class RouteProgress {
  const RouteProgress({
    this.waypoints = const [],
    this.currentIndex = 0,
    this.position,
    this.headingDegrees,
    this.targetBearing,
    this.accuracyMeters,
    this.remainingMeters = 0,
    this.walkedMeters = 0,
    this.remainingPath = const [],
    this.walkedPath = const [],
    this.trailBreakIndices = const [],
    this.destination,
    this.destinationName,
    this.status = NavigationStatus.locating,
    this.message = 'Đang tìm vị trí GPS...',
    this.updatedAt,
    this.lastRouteUpdate,
    this.streetName = '',
    this.crossTrackMeters = 0,
  });

  final List<Waypoint> waypoints;
  final int currentIndex;
  final GeoPoint? position;
  final double? headingDegrees;
  final double? targetBearing;
  final double? accuracyMeters;
  final double remainingMeters;
  final double walkedMeters;
  final List<GeoPoint> remainingPath;
  final List<GeoPoint> walkedPath;
  final List<int> trailBreakIndices;
  final GeoPoint? destination;
  final String? destinationName;
  final NavigationStatus status;
  final String message;
  final DateTime? updatedAt;
  final DateTime? lastRouteUpdate;
  final String streetName;
  final double crossTrackMeters;
  double get currentLat => position?.lat ?? 0;
  double get currentLng => position?.lng ?? 0;
}
