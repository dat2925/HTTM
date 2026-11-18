import '../models/detection_result.dart';

/// Visual attention policy, separate from model output and speech scheduling.
/// No depth, free-space, route intersection or collision probability is inferred.
class RiskAssessmentService {
  static const ttl = Duration(seconds: 5);
  static const emptyObservationHold = Duration(seconds: 2);

  List<DetectedObject> candidates(List<DetectedObject> objects, DateTime now) =>
      objects
          .where((o) {
            final at = o.observedAt;
            return at != null &&
                !at.isAfter(now) &&
                now.difference(at) <= ttl &&
                o.confidence.isFinite &&
                o.confidence >= .35 &&
                o.confidence <= 1 &&
                (o.isStable || o.danger == DangerLevel.high);
          })
          .toList(growable: false);

  double priority(DetectedObject o) {
    // Keep high-tier/centre ordering dominant; smaller terms break ties only.
    final center = o.position == 'center';
    final classAttention =
        center &&
        const [
          'pothole',
          'motorcycle',
          'car',
          'bus',
          'truck',
        ].contains(o.className);
    final growth = o.heightGrowthPerSecond;
    return o.danger.score +
        (center ? 2 : 0) +
        (classAttention ? .2 : 0) +
        o.confidence * .1 +
        (o.isStable ? .1 : 0) +
        (o.isStable && growth != null && growth.isFinite && growth > .15
            ? .1
            : 0);
  }
}
