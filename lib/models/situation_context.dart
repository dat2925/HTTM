import 'detection_result.dart';
import 'route_progress.dart';

class SituationEvent {
  const SituationEvent({
    required this.kind,
    required this.key,
    required this.priority,
    required this.createdAt,
    required this.expiresAt,
  });
  final String kind, key;
  final int priority;
  final DateTime createdAt, expiresAt;
}

/// Snapshot of reported evidence, never a certificate that a path is traversable.
class SituationContext {
  const SituationContext({
    required this.timestamp,
    required this.revision,
    required this.navigation,
    required this.detections,
    required this.sourceFreshness,
    required this.observations,
    required this.uncertainty,
    required this.events,
    this.yoloAt,
    this.imageAt,
    this.maneuverMeters,
    this.watchCategory,
  });
  final DateTime timestamp;
  final int revision;
  final RouteProgress navigation;
  final List<DetectedObject> detections;
  final Map<String, bool> sourceFreshness;
  final List<String> observations, uncertainty;
  final List<SituationEvent> events;
  final DateTime? yoloAt, imageAt;
  final double? maneuverMeters;
  final String? watchCategory;

  String get sceneKey {
    final keys =
        detections.map((o) => '${o.className}:${o.position}').toSet().toList()
          ..sort();
    return keys.join('|');
  }

  Map<String, dynamic> toNavigationJson() {
    final p = navigation;
    final gps = sourceFreshness['gps']!;
    final route = sourceFreshness['navigation']!;
    final waypoint = p.currentIndex < p.waypoints.length
        ? p.waypoints[p.currentIndex]
        : null;
    return {
      'captured_at': timestamp.toUtc().toIso8601String(),
      'position': !gps
          ? null
          : {'lat': p.position!.lat, 'lng': p.position!.lng},
      'gps_updated_at': p.updatedAt?.toUtc().toIso8601String(),
      'accuracy_meters': p.accuracyMeters,
      'heading_degrees': sourceFreshness['heading']! ? p.headingDegrees : null,
      'heading_updated_at': p.headingUpdatedAt?.toUtc().toIso8601String(),
      'target_bearing': route ? p.targetBearing : null,
      'status': p.status.name,
      'route_message': p.message,
      'street_name': gps ? p.streetName : '',
      'destination': p.destination == null
          ? null
          : {'lat': p.destination!.lat, 'lng': p.destination!.lng},
      'destination_name': p.destinationName,
      'remaining_meters': p.remainingMeters,
      'walked_meters': p.walkedMeters,
      'route_updated_at': p.lastRouteUpdate?.toUtc().toIso8601String(),
      'maneuver_index': p.currentIndex,
      'next_maneuver_type': route ? waypoint?.type : null,
      'next_maneuver_meters': maneuverMeters,
      'next_instructions': route
          ? p.waypoints
                .skip(p.currentIndex)
                .take(8)
                .map((w) => w.instruction)
                .toList()
          : <String>[],
      'obstacles': detections
          .take(20)
          .map(
            (o) => {
              'class_name': o.className,
              'position': o.position,
              'danger': o.danger.name,
              'confidence': o.confidence,
            },
          )
          .toList(),
      'yolo_updated_at': yoloAt?.toUtc().toIso8601String(),
      'image_captured_at': imageAt?.toUtc().toIso8601String(),
      'situation_changes': events.take(12).map((e) => e.kind).toList(),
      'watch_category': watchCategory,
    };
  }
}
