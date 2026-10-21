import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/geo_point.dart';

class JourneyRecord {
  const JourneyRecord({
    this.points = const [],
    this.breakIndices = const [],
    this.walkedMeters = 0,
    this.destination,
    this.destinationName,
  });
  final List<GeoPoint> points;
  final List<int> breakIndices;
  final double walkedMeters;
  final GeoPoint? destination;
  final String? destinationName;
}

/// The last journey is stored on this device; route geometry is always refreshed.
class JourneyStore {
  late final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  Future<void> _pending = Future.value();
  Future<JourneyRecord> load() async {
    try {
      final raw = await _preferences.getString('walking_journey_v1');
      if (raw == null) return const JourneyRecord();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return JourneyRecord(
        points: (json['points'] as List)
            .map((p) => GeoPoint.fromJson(p as List))
            .toList(),
        breakIndices: (json['break_indices'] as List? ?? [])
            .map((i) => (i as num).toInt())
            .toList(),
        walkedMeters: (json['walked_meters'] as num).toDouble(),
        destination: json['destination'] == null
            ? null
            : GeoPoint.fromJson(json['destination'] as List),
        destinationName: json['destination_name'] as String?,
      );
    } catch (_) {
      return const JourneyRecord();
    }
  }

  Future<void> save(JourneyRecord record) {
    final json = jsonEncode({
      'points': record.points.map((p) => p.toJson()).toList(),
      'break_indices': record.breakIndices,
      'walked_meters': record.walkedMeters,
      'destination': record.destination?.toJson(),
      'destination_name': record.destinationName,
    });
    _pending = _pending
        .catchError((Object _) {})
        .then((_) => _preferences.setString('walking_journey_v1', json));
    return _pending;
  }
}
