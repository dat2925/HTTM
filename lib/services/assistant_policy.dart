import '../models/route_progress.dart';
import '../models/situation_context.dart';

/// Proactivity is event-driven, deduplicated and never part of the safety loop.
class AssistantProactivityPolicy {
  DateTime? _lastTriggered;
  final Map<String, DateTime> _seen = {};
  SituationEvent? candidateSituation(SituationContext context, DateTime now) {
    if (context.navigation.status == NavigationStatus.paused) return null;
    final candidates =
        context.events.where((e) => e.expiresAt.isAfter(now)).toList()..sort((
          a,
          b,
        ) {
          final priority = b.priority.compareTo(a.priority);
          return priority != 0 ? priority : b.createdAt.compareTo(a.createdAt);
        });
    for (final event in candidates) {
      if (_accept(event.key, now)) return event;
    }
    return null;
  }

  bool _accept(String key, DateTime now) {
    _seen.removeWhere(
      (_, at) => now.difference(at) >= const Duration(minutes: 10),
    );
    if ((_lastTriggered != null &&
            now.difference(_lastTriggered!) < const Duration(seconds: 120)) ||
        _seen.containsKey(key)) {
      return false;
    }
    _seen[key] = now;
    _lastTriggered = now;
    if (_seen.length > 30) _seen.remove(_seen.keys.first);
    return true;
  }

  String? candidate(RouteProgress progress, DateTime now) {
    final event = switch (progress.status) {
      NavigationStatus.offRoute => 'offRoute',
      NavigationStatus.error => 'error',
      NavigationStatus.poorGps => 'poorGps',
      _ => null,
    };
    if (event == null) return null;
    final key = '$event:${progress.destinationName ?? ''}:${progress.message}';
    return _accept(key, now) ? event : null;
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
        captured.currentIndex != current.currentIndex ||
        captured.status != current.status) {
      return false;
    }
    if (captured.position != null &&
        current.position != null &&
        captured.position!.distanceTo(current.position!) > 10) {
      return false;
    }
    if (captured.headingDegrees != null &&
        current.headingDegrees != null &&
        (((captured.headingDegrees! - current.headingDegrees! + 180) % 360) -
                    180)
                .abs() >
            30) {
      return false;
    }
    return true;
  }
}
