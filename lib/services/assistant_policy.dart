import '../models/route_progress.dart';

/// Proactivity is event-driven, deduplicated and never part of the safety loop.
class AssistantProactivityPolicy {
  DateTime? _lastTriggered;
  final Map<String, DateTime> _seen = {};
  String? candidate(RouteProgress progress, DateTime now) {
    final event = switch (progress.status) {
      NavigationStatus.offRoute => 'offRoute',
      NavigationStatus.error => 'error',
      NavigationStatus.poorGps => 'poorGps',
      _ => null,
    };
    if (event == null) return null;
    if (_lastTriggered != null &&
        now.difference(_lastTriggered!) < const Duration(seconds: 120)) {
      return null;
    }
    final key = '$event:${progress.destinationName ?? ''}:${progress.message}';
    if (_seen[key] != null &&
        now.difference(_seen[key]!) < const Duration(minutes: 10)) {
      return null;
    }
    _seen[key] = now;
    _lastTriggered = now;
    if (_seen.length > 30) _seen.remove(_seen.keys.first);
    return event;
  }

  static bool contextStillCurrent(
    RouteProgress captured,
    RouteProgress current,
    DateTime requestedAt,
    DateTime now,
  ) {
    if (now.difference(requestedAt) > const Duration(seconds: 30) ||
        current.status == NavigationStatus.paused) {
      return false;
    }
    if (captured.destination?.lat != current.destination?.lat ||
        captured.destination?.lng != current.destination?.lng ||
        captured.lastRouteUpdate != current.lastRouteUpdate ||
        captured.status != current.status) {
      return false;
    }
    if (captured.position != null &&
        current.position != null &&
        captured.position!.distanceTo(current.position!) > 10) {
      return false;
    }
    return true;
  }
}
