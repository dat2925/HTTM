import 'waypoint.dart';

/// Snapshot of route-following state for the visual debug screen: the full
/// waypoint list, which one is active, and the real GPS position used to
/// drive that decision.
class RouteProgress {
  const RouteProgress({
    required this.waypoints,
    required this.currentIndex,
    required this.currentLat,
    required this.currentLng,
    required this.remainingMeters,
  });

  final List<Waypoint> waypoints;
  final int currentIndex;
  final double currentLat;
  final double currentLng;
  final double remainingMeters;
}
