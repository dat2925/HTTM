// Named constructor params below keep a clean public API name instead of
// matching the private field name, so initializing formals don't apply.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:geolocator/geolocator.dart';

class RouteInstruction {
  const RouteInstruction({required this.text, required this.remainingMeters});

  final String text;
  final double remainingMeters;
}

abstract class RouteService {
  Stream<RouteInstruction> get instructions;
  void start();
  void stop();
  void setDestination(double lat, double lng);
  void dispose();
}

/// Real-GPS route heuristic: there is no turn-by-turn/Directions API backend,
/// so this only reports true distance and a left/right/straight guess based
/// on the bearing to a fixed demo destination vs. the device's GPS heading.
/// Not real turn-by-turn guidance.
class GeolocatorRouteService implements RouteService {
  GeolocatorRouteService({
    required double destinationLat,
    required double destinationLng,
  }) : _destinationLat = destinationLat,
       _destinationLng = destinationLng;

  double _destinationLat;
  double _destinationLng;
  Position? _lastPosition;

  final StreamController<RouteInstruction> _controller =
      StreamController<RouteInstruction>.broadcast();
  StreamSubscription<Position>? _positionSubscription;

  @override
  Stream<RouteInstruction> get instructions => _controller.stream;

  @override
  void start() {
    if (_positionSubscription != null) return;
    unawaited(_startWhenPermitted());
  }

  Future<void> _startWhenPermitted() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) return;

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen(_onPosition, onError: (_) {});
  }

  @override
  void setDestination(double lat, double lng) {
    _destinationLat = lat;
    _destinationLng = lng;
    final position = _lastPosition;
    if (position != null) _onPosition(position);
  }

  void _onPosition(Position position) {
    _lastPosition = position;
    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      _destinationLat,
      _destinationLng,
    );
    final bearingToDestination = Geolocator.bearingBetween(
      position.latitude,
      position.longitude,
      _destinationLat,
      _destinationLng,
    );
    final turnText = _turnFor(position.heading, bearingToDestination);
    _controller.add(
      RouteInstruction(
        text: '$turnText · còn ${distance.round()} m',
        remainingMeters: distance,
      ),
    );
  }

  String _turnFor(double heading, double bearingToDestination) {
    if (heading.isNaN) return 'Đi thẳng';
    var delta = bearingToDestination - heading;
    delta = ((delta + 180) % 360) - 180;
    if (delta < -20) return 'Rẽ trái';
    if (delta > 20) return 'Rẽ phải';
    return 'Đi thẳng';
  }

  @override
  void stop() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  @override
  void dispose() {
    stop();
    _controller.close();
  }
}
