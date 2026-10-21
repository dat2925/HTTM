import 'package:geolocator/geolocator.dart';
import '../models/geo_point.dart';

class NavigationFix {
  const NavigationFix({
    required this.point,
    required this.accuracy,
    required this.timestamp,
    this.speed = 0,
  });
  final GeoPoint point;
  final double accuracy;
  final DateTime timestamp;
  final double speed;
  factory NavigationFix.fromPosition(Position position) => NavigationFix(
    point: GeoPoint(position.latitude, position.longitude),
    accuracy: position.accuracy,
    timestamp: position.timestamp,
    speed: position.speed,
  );
}

abstract class LocationSource {
  Future<void> ensureAvailable();
  Stream<NavigationFix> get fixes;
  Future<NavigationFix> current();
}

class DeviceLocationSource implements LocationSource {
  @override
  Future<void> ensureAvailable() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('GPS đang tắt. Hãy bật vị trí trên điện thoại.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Hãy cấp quyền vị trí trong cài đặt ứng dụng.');
    }
    if (permission == LocationPermission.denied) {
      throw Exception('Chưa được cấp quyền vị trí.');
    }
  }

  @override
  Stream<NavigationFix> get fixes => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    ),
  ).map(NavigationFix.fromPosition);
  @override
  Future<NavigationFix> current() async => NavigationFix.fromPosition(
    await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        timeLimit: Duration(seconds: 12),
      ),
    ),
  );
}
