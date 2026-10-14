import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/services/obstacle_reasoning_service.dart';

void main() {
  const centerMedium = DetectedObject(
    className: 'person',
    confidence: 0.9,
    position: 'center',
    danger: DangerLevel.medium,
    areaRatio: 0.1,
    x1: 100,
    y1: 100,
    x2: 200,
    y2: 300,
  );
  const leftHigh = DetectedObject(
    className: 'car',
    confidence: 0.8,
    position: 'left',
    danger: DangerLevel.high,
    areaRatio: 0.2,
    x1: 0,
    y1: 50,
    x2: 150,
    y2: 250,
  );

  test('center priority bonus selects the centered obstacle', () {
    final warning = ObstacleReasoningService().selectWarning([
      leftHigh,
      centerMedium,
    ]);

    expect(warning?.object, centerMedium);
    expect(warning?.text, 'Phía trước có người.');
  });

  test('empty detections produce no warning', () {
    expect(ObstacleReasoningService().selectWarning(const []), isNull);
  });
}
