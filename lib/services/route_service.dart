// Named constructor params below keep a clean public API name instead of
// matching the private field name, so initializing formals don't apply.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/route_progress.dart';
import '../models/waypoint.dart';
import 'compass_service.dart';
import 'route_planning_service.dart';

class RouteInstruction {
  const RouteInstruction({required this.text, required this.remainingMeters});

  final String text;
  final double remainingMeters;
}

/// Compares where the phone is physically pointed ([headingDegrees], 0 =
/// north, from the magnetometer) against the bearing to a target
/// coordinate, and returns what the user should do next. This is what
/// answers "I'm standing here, which way do I even go?" — `Position.heading`
/// (GPS course-over-ground) cannot answer that because it's only defined
/// once you're already moving.
String facingInstruction(double headingDegrees, double bearingDegrees) {
  var delta = bearingDegrees - headingDegrees;
  delta = ((delta + 180) % 360) - 180;
  if (delta.abs() <= 20) return 'Đi thẳng';
  if (delta.abs() >= 150) return 'Quay lại';
  return delta < 0 ? 'Quay sang trái' : 'Quay sang phải';
}

abstract class RouteService {
  Stream<RouteInstruction> get instructions;

  /// Waypoint list + active index + real GPS position, for the visual
  /// route-debug screen. Implementations without real waypoints (e.g. the
  /// bearing-only heuristic) still emit a 1-waypoint progress so the debug
  /// screen has something to draw.
  Stream<RouteProgress> get progress;
  void start();
  void stop();
  void setDestination(double lat, double lng);
  void dispose();
}

/// Real-GPS + real-compass route heuristic: there is no turn-by-turn/
/// Directions API backend, so this only reports true distance and a
/// facing correction (see [facingInstruction]) toward a fixed demo
/// destination. Not real turn-by-turn guidance, but the direction itself
/// is real and works even before the user starts moving.
class GeolocatorRouteService implements RouteService {
  GeolocatorRouteService({
    required double destinationLat,
    required double destinationLng,
    CompassService? compassService,
  }) : _destinationLat = destinationLat,
       _destinationLng = destinationLng,
       _compassService = compassService ?? CompassService();

  double _destinationLat;
  double _destinationLng;
  final CompassService _compassService;
  Position? _lastPosition;
  double? _lastHeading;

  final StreamController<RouteInstruction> _controller =
      StreamController<RouteInstruction>.broadcast();
  final StreamController<RouteProgress> _progressController =
      StreamController<RouteProgress>.broadcast();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<double>? _headingSubscription;

  @override
  Stream<RouteInstruction> get instructions => _controller.stream;

  @override
  Stream<RouteProgress> get progress => _progressController.stream;

  @override
  void start() {
    _headingSubscription ??= _compassService.heading.listen(_onHeading);
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
    if (position != null) _recompute(position);
  }

  void _onPosition(Position position) {
    _lastPosition = position;
    _recompute(position);
  }

  void _onHeading(double heading) {
    _lastHeading = heading;
    final position = _lastPosition;
    if (position != null) _recompute(position);
  }

  void _recompute(Position position) {
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
    final heading = _lastHeading;
    final turnText = heading == null
        ? 'Đang xác định hướng la bàn...'
        : facingInstruction(heading, bearingToDestination);
    _controller.add(
      RouteInstruction(
        text: '$turnText · còn ${distance.round()} m',
        remainingMeters: distance,
      ),
    );
    _progressController.add(
      RouteProgress(
        waypoints: [
          Waypoint(
            lat: _destinationLat,
            lng: _destinationLng,
            distanceMeters: distance,
            instruction: turnText,
          ),
        ],
        currentIndex: 0,
        currentLat: position.latitude,
        currentLng: position.longitude,
        remainingMeters: distance,
      ),
    );
  }

  @override
  void stop() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _headingSubscription?.cancel();
    _headingSubscription = null;
  }

  @override
  void dispose() {
    stop();
    _controller.close();
    _progressController.close();
  }
}

/// Real turn-by-turn route following: fetches a waypoint list from
/// `ai_server`'s OSRM proxy (see [RoutePlanningService]) and advances
/// through it as the real GPS position gets close to each maneuver point.
/// Idle (no instructions) until [setDestination] resolves a route.
class OsrmRouteService implements RouteService {
  OsrmRouteService({
    RoutePlanningService? planningService,
    CompassService? compassService,
  }) : _planningService = planningService ?? RoutePlanningService(),
       _compassService = compassService ?? CompassService();

  static const double _arrivalThresholdMeters = 15;
  static const double _approachingThresholdMeters = 20;

  final RoutePlanningService _planningService;
  final CompassService _compassService;
  final StreamController<RouteInstruction> _controller =
      StreamController<RouteInstruction>.broadcast();
  final StreamController<RouteProgress> _progressController =
      StreamController<RouteProgress>.broadcast();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<double>? _headingSubscription;

  List<Waypoint> _waypoints = const [];
  int _currentIndex = 0;
  Position? _lastPosition;
  double? _lastHeading;

  @override
  Stream<RouteInstruction> get instructions => _controller.stream;

  @override
  Stream<RouteProgress> get progress => _progressController.stream;

  @override
  void start() {
    _headingSubscription ??= _compassService.heading.listen(_onHeading);
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

  void _onHeading(double heading) {
    _lastHeading = heading;
    final position = _lastPosition;
    if (position != null && _waypoints.isNotEmpty) _emitCurrent(position);
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
    _lastPosition = position;
    final isLast = _currentIndex == _waypoints.length - 1;
    final current = _waypoints[_currentIndex];

    if (isLast) {
      _controller.add(
        RouteInstruction(text: current.instruction, remainingMeters: 0),
      );
      _progressController.add(
        RouteProgress(
          waypoints: _waypoints,
          currentIndex: _currentIndex,
          currentLat: position.latitude,
          currentLng: position.longitude,
          remainingMeters: 0,
        ),
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
    final upcomingInstruction = remaining <= _approachingThresholdMeters
        ? next.instruction
        : current.instruction;

    // OSRM's "turn left/right" phrasing assumes you're already driving
    // along the road; a pedestrian standing still needs to know which way
    // to physically face first. Prefer that real compass-based correction
    // whenever the phone isn't already pointed the right way.
    final bearingToNext = Geolocator.bearingBetween(
      position.latitude,
      position.longitude,
      next.lat,
      next.lng,
    );
    final heading = _lastHeading;
    final facing = heading == null
        ? null
        : facingInstruction(heading, bearingToNext);
    final text = (facing == null || facing == 'Đi thẳng')
        ? '$upcomingInstruction · còn ${remaining.round()} m'
        : '$facing · còn ${remaining.round()} m';

    _controller.add(RouteInstruction(text: text, remainingMeters: remaining));
    _progressController.add(
      RouteProgress(
        waypoints: _waypoints,
        currentIndex: _currentIndex,
        currentLat: position.latitude,
        currentLng: position.longitude,
        remainingMeters: remaining,
      ),
    );
  }

  @override
  void stop() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _headingSubscription?.cancel();
    _headingSubscription = null;
  }

  @override
  void dispose() {
    stop();
    _planningService.dispose();
    _controller.close();
    _progressController.close();
  }
}
