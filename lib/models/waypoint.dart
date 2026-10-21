/// One maneuver point along an OSRM route: "at (lat, lng), do
/// [instruction], then travel [distanceMeters] before the next waypoint."
class Waypoint {
  const Waypoint({
    required this.lat,
    required this.lng,
    required this.distanceMeters,
    required this.instruction,
    this.shapeIndex = 0,
    this.type = 'turn',
    this.streetName = '',
  });

  final double lat;
  final double lng;
  final double distanceMeters;
  final String instruction;
  final int shapeIndex;
  final String type;
  final String streetName;

  factory Waypoint.fromJson(Map<String, dynamic> json) {
    return Waypoint(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      instruction: json['instruction']?.toString() ?? 'Đi theo tuyến đường',
      shapeIndex: (json['shape_index'] as num).toInt(),
      type: json['type']?.toString() ?? 'turn',
      streetName: json['street_name']?.toString() ?? '',
    );
  }
}
