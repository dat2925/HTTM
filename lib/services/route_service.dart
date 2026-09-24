// Named constructor params below keep a clean public API name instead of
// matching the private field name, so initializing formals don't apply.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/waypoint.dart';
import 'route_planning_service.dart';

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

/// Real turn-by-turn route following: fetches a waypoint list from
/// `ai_server`'s OSRM proxy (see [RoutePlanningService]) and advances
/// through it as the real GPS position gets close to each maneuver point.
/// Idle (no instructions) until [setDestination] resolves a route.
class OsrmRouteService implements RouteService {
  OsrmRouteService({RoutePlanningService? planningService})
    : _planningService = planningService ?? RoutePlanningService();

  static const double _arrivalThresholdMeters = 15;
  static const double _approachingThresholdMeters = 20;

  final RoutePlanningService _planningService;
  final StreamController<RouteInstruction> _controller =
      StreamController<RouteInstruction>.broadcast();
  StreamSubscription<Position>? _positionSubscription;

  List<Waypoint> _waypoints = const [];
  int _currentIndex = 0;

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
    unawaited(_planRoute(lat, lng));
  }

  Future<void> _planRoute(double lat, double lng) async {
    Position from;
    try {
      from = await Geolocator.getCurrentPosition();
    } catch (_) {
      return;
    }
    try {
      final waypoints = await _planningService.plan(
        fromLat: from.latitude,
        fromLng: from.longitude,
        toLat: lat,
        toLng: lng,
      );
      _waypoints = waypoints;
      _currentIndex = 0;
      _emitCurrent(from);
    } on RoutePlanningException {
      // Keep whatever route was already active; SessionController reports
      // the geocode/route failure to the user via TTS separately.
    }
  }

  void _onPosition(Position position) {
    if (_waypoints.isEmpty) return;
    _advanceIfArrived(position);
    _emitCurrent(position);
  }

  void _advanceIfArrived(Position position) {
    while (_currentIndex < _waypoints.length - 1) {
      final next = _waypoints[_currentIndex + 1];
      final distanceToNext = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        next.lat,
        next.lng,
      );
      if (distanceToNext > _arrivalThresholdMeters) break;
      _currentIndex++;
    }
  }

  void _emitCurrent(Position position) {
    final isLast = _currentIndex == _waypoints.length - 1;
    final current = _waypoints[_currentIndex];
    if (isLast) {
      _controller.add(
        RouteInstruction(text: current.instruction, remainingMeters: 0),
      );
      return;
    }

    final next = _waypoints[_currentIndex + 1];
    final remaining = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      next.lat,
      next.lng,
    );
    final text = remaining <= _approachingThresholdMeters
        ? '${next.instruction} sau ${remaining.round()} m'
        : '${current.instruction} · còn ${remaining.round()} m';
    _controller.add(RouteInstruction(text: text, remainingMeters: remaining));
  }

  @override
  void stop() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  @override
  void dispose() {
    stop();
    _planningService.dispose();
    _controller.close();
  }
}
