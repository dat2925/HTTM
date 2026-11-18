import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/services/risk_assessment_service.dart';
import 'package:smart_navigation/services/obstacle_reasoning_service.dart';

void main() {
  final now = DateTime.utc(2026, 11, 18);
  final risk = RiskAssessmentService();
  DetectedObject object({
    int hits = 1,
    DangerLevel danger = DangerLevel.medium,
    double confidence = .8,
    String name = 'pole',
    String side = 'center',
    DateTime? at,
    double? growth,
  }) =>
      DetectedObject(
        className: name,
        confidence: confidence,
        position: side,
        danger: danger,
        areaRatio: .1,
        x1: 10,
        y1: 10,
        x2: 20,
        y2: 80,
      ).withTrack(
        id: 1,
        at: at ?? now,
        firstAt: now,
        hits: hits,
        heightGrowth: growth,
      );

  test('ordinary noise requires confirmation, high priority is immediate', () {
    expect(risk.candidates([object()], now), isEmpty);
    expect(risk.candidates([object(hits: 2)], now), hasLength(1));
    expect(
      risk.candidates([object(danger: DangerLevel.high)], now),
      hasLength(1),
    );
  });
  test('stale, future, nonfinite and low confidence evidence cannot alert', () {
    for (final o in [
      object(hits: 2, at: now.subtract(const Duration(seconds: 6))),
      object(hits: 2, at: now.add(const Duration(seconds: 1))),
      object(hits: 2, confidence: double.nan),
      object(hits: 2, confidence: .2),
    ]) {
      expect(risk.candidates([o], now), isEmpty);
    }
  });
  test(
    'class, confidence, stability and image growth break visual attention ties',
    () {
      final pole = object(hits: 2);
      final pothole = object(hits: 2, name: 'pothole', growth: .2);
      expect(risk.priority(pothole), greaterThan(risk.priority(pole)));
      final warning = ObstacleReasoningService().selectWarning([
        pole,
        pothole,
      ], priority: risk.priority)!;
      expect(warning.object.className, 'pothole');
      expect('${warning.text} ${warning.speech}', isNot(contains('mét')));
      expect('${warning.text} ${warning.speech}', isNot(contains('an toàn')));
      expect(risk.candidates([], now), isEmpty);
    },
  );
}
