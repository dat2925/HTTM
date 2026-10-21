import 'dart:math' as math;

class GeoPoint {
  const GeoPoint(this.lat, this.lng);
  final double lat;
  final double lng;
  List<double> toJson() => [lat, lng];
  factory GeoPoint.fromJson(List<dynamic> json) {
    final point = GeoPoint(
      (json[0] as num).toDouble(),
      (json[1] as num).toDouble(),
    );
    if (!point.lat.isFinite ||
        !point.lng.isFinite ||
        point.lat.abs() > 90 ||
        point.lng.abs() > 180) {
      throw const FormatException('Invalid coordinate');
    }
    return point;
  }
  double distanceTo(GeoPoint other) {
    const rad = math.pi / 180;
    final a =
        math.pow(math.sin((other.lat - lat) * rad / 2), 2) +
        math.cos(lat * rad) *
            math.cos(other.lat * rad) *
            math.pow(math.sin((other.lng - lng) * rad / 2), 2);
    return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
  }

  double bearingTo(GeoPoint other) {
    const rad = math.pi / 180;
    final delta = (other.lng - lng) * rad;
    return (math.atan2(
                  math.sin(delta) * math.cos(other.lat * rad),
                  math.cos(lat * rad) * math.sin(other.lat * rad) -
                      math.sin(lat * rad) *
                          math.cos(other.lat * rad) *
                          math.cos(delta),
                ) /
                rad +
            360) %
        360;
  }
}
