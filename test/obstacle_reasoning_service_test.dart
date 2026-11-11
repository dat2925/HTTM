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
    expect(
      warning?.text,
      startsWith('Camera ghi nhận người ở giữa khung hình.'),
    );
    expect(warning?.text, contains('nhiều đối tượng'));
  });

  test('empty detections produce no warning', () {
    expect(ObstacleReasoningService().selectWarning(const []), isNull);
  });
  test('detection ordering does not generate a different spoken warning', () {
    final reasoning = ObstacleReasoningService();
    expect(
      reasoning.selectWarning([centerMedium, leftHigh])!.text,
      reasoning.selectWarning([leftHigh, centerMedium])!.text,
    );
  });

  test('new HTTM canonical classes map to Vietnamese names and categories', () {
    for (final name in ['pole', 'tree', 'pothole', 'trash_bin', 'signboard']) {
      expect(ObstacleReasoningService.category(name), 'obstacle');
    }
    expect(ObstacleReasoningService.category('traffic_light'), 'other');

    final reasoning = ObstacleReasoningService();
    final summary = reasoning.summarize(const [
      DetectedObject(
        className: 'pothole',
        confidence: 0.9,
        position: 'center',
        danger: DangerLevel.high,
        areaRatio: 0.03,
        x1: 100,
        y1: 200,
        x2: 150,
        y2: 260,
      ),
      DetectedObject(
        className: 'pole',
        confidence: 0.85,
        position: 'left',
        danger: DangerLevel.medium,
        areaRatio: 0.06,
        x1: 10,
        y1: 50,
        x2: 40,
        y2: 250,
      ),
      DetectedObject(
        className: 'tree',
        confidence: 0.8,
        position: 'left',
        danger: DangerLevel.low,
        areaRatio: 0.04,
        x1: 20,
        y1: 20,
        x2: 60,
        y2: 180,
      ),
      DetectedObject(
        className: 'trash_bin',
        confidence: 0.8,
        position: 'right',
        danger: DangerLevel.low,
        areaRatio: 0.03,
        x1: 220,
        y1: 150,
        x2: 260,
        y2: 240,
      ),
      DetectedObject(
        className: 'signboard',
        confidence: 0.8,
        position: 'right',
        danger: DangerLevel.low,
        areaRatio: 0.04,
        x1: 210,
        y1: 30,
        x2: 280,
        y2: 100,
      ),
      DetectedObject(
        className: 'traffic_light',
        confidence: 0.9,
        position: 'center',
        danger: DangerLevel.low,
        areaRatio: 0.02,
        x1: 120,
        y1: 10,
        x2: 140,
        y2: 50,
      ),
    ]);

    expect(summary[0], 'Giữa khung hình: 1 ổ gà, 1 đèn giao thông.');
    expect(summary[1], 'Trái khung hình: 1 cột, 1 cây.');
    expect(summary[2], 'Phải khung hình: 1 bảng hiệu, 1 thùng rác.');

    final potholeWarning = reasoning.selectWarning(const [
      DetectedObject(
        className: 'pothole',
        confidence: 0.9,
        position: 'center',
        danger: DangerLevel.high,
        areaRatio: 0.03,
        x1: 100,
        y1: 200,
        x2: 150,
        y2: 260,
      ),
    ]);
    expect(
      potholeWarning?.text,
      'Camera ghi nhận ổ gà ở giữa khung hình. Nên dừng lại kiểm tra.',
    );
  });
}
