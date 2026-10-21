class Placemark {
  const Placemark({
    required this.lat,
    required this.lng,
    required this.displayName,
  });

  final double lat;
  final double lng;
  final String displayName;

  factory Placemark.fromJson(Map<String, dynamic> json) {
    return Placemark(
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      displayName: json['display_name']?.toString() ?? '',
    );
  }
}
