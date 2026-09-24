/// One maneuver point along an OSRM route: "at (lat, lng), do
/// [instruction], then travel [distanceMeters] before the next waypoint."
class Waypoint {
  const Waypoint({
    required this.lat,
    required this.lng,
    required this.distanceMeters,
    required this.instruction,
  });

  final double lat;
  final double lng;
  final double distanceMeters;
  final String instruction;

  factory Waypoint.fromJson(Map<String, dynamic> json) {
    return Waypoint(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      distanceMeters: (json['distance_meters'] as num).toDouble(),
      instruction: json['instruction']?.toString() ?? 'Đi theo tuyến đường',
    );
  }
}
