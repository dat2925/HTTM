import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/services/compass_service.dart';

void main() {
  test('facing prefers the camera-axis heading and normalises it', () {
    expect(CompassService.facingDegrees(10, 200), 200);
    expect(CompassService.facingDegrees(10, -90), 270);
    expect(CompassService.facingDegrees(370, null), 10);
    expect(CompassService.facingDegrees(10, double.nan), 10);
    expect(CompassService.facingDegrees(null, null), isNull);
    expect(CompassService.facingDegrees(double.infinity, null), isNull);
  });
}
