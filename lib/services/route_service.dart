import 'dart:async';
import 'dart:math' as math;
import '../config/ai_config.dart';
import '../models/geo_point.dart';
import '../models/route_progress.dart';
import 'compass_service.dart';
import 'journey_store.dart';
import 'location_source.dart';
import 'route_planning_service.dart';
import 'route_tracker.dart';

class RouteInstruction {
  const RouteInstruction({
    required this.text,
    this.remainingMeters = 0,
    this.key = '',
    this.urgent = false,
  });
  final String text;
  final double remainingMeters;
  final String key;
  final bool urgent;
}

String facingInstruction(double headingDegrees, double bearingDegrees) {
  final delta = ((bearingDegrees - headingDegrees + 180) % 360) - 180;
  if (delta.abs() <= 25) return 'Đi thẳng';
  if (delta.abs() >= 150) return 'Quay lại';
  return delta < 0 ? 'Quay sang trái' : 'Quay sang phải';
}

String cardinalDirection(double degrees) {
  const directions = [
    'Bắc',
    'Đông Bắc',
    'Đông',
    'Đông Nam',
    'Nam',
    'Tây Nam',
    'Tây',
    'Tây Bắc',
  ];
  return directions[((degrees + 22.5) % 360 ~/ 45)];
}

abstract class RouteService {
  Stream<RouteInstruction> get instructions;
  Stream<RouteProgress> get progress;
  RouteProgress get snapshot;
  Future<void> start();
  void stop();
  Future<bool> setDestination(double lat, double lng, {String? name});
  Future<void> refresh();
  void cancelDestination();
  Future<void> clearJourney();
  Future<void> dispose();
}

/// GPS trail and route-to-go are separate. Only the remaining path is replanned.
class PedestrianRouteService implements RouteService {
  PedestrianRouteService({
    RoutePlanningService? planningService,
    CompassService? compassService,
    LocationSource? locationSource,
    JourneyStore? journeyStore,
    this.refreshInterval = AiConfig.routeRefreshInterval,
    this.checkInterval = const Duration(seconds: 5),
    DateTime Function()? now,
  }) : _planningService = planningService ?? RoutePlanningService(),
       _compassService = compassService ?? CompassService(),
       _locationSource = locationSource ?? DeviceLocationSource(),
       _journeyStore = journeyStore ?? JourneyStore(),
       _now = now ?? DateTime.now;

  final RoutePlanningService _planningService;
  final CompassService _compassService;
  final LocationSource _locationSource;
  final JourneyStore _journeyStore;
  final Duration refreshInterval;
  final Duration checkInterval;
  final DateTime Function() _now;
  final _instructions = StreamController<RouteInstruction>.broadcast();
  final _progress = StreamController<RouteProgress>.broadcast();
  StreamSubscription<NavigationFix>? _gpsSubscription;
  StreamSubscription<double>? _headingSubscription;
  Timer? _timer;
  NavigationFix? _fix;
  double? _heading;
  DateTime? _headingAt;
  DateTime? _headingPublishedAt;
  bool _pollingFix = false;
  GeoPoint? _destination;
  String? _destinationName;
  GeoPoint? _plannedFrom;
  DateTime? _lastRequestAt;
  DateTime? _lastRouteAt;
  DateTime? _lastSaveAt;
  NavigationFix? _lastRecordedFix;
  RouteTracker? _tracker;
  RouteMatch? _match;
  final List<GeoPoint> _trail = [];
  final List<int> _trailBreaks = [];
  double _walkedMeters = 0;
  bool _active = false, _disposed = false, _loaded = false, _arrived = false;
  Future<void>? _starting;
  int _generation = 0;
  int _lifecycle = 0;
  int? _planningGeneration;
  int _offRouteFixes = 0, _arrivalFixes = 0;
  String? _routeError;
  RouteProgress _snapshot = const RouteProgress();

  @override
  Stream<RouteInstruction> get instructions => _instructions.stream;
  @override
  Stream<RouteProgress> get progress => _progress.stream;
  @override
  RouteProgress get snapshot => _snapshot;

  @override
  Future<void> start() {
    if (_disposed) return Future.value();
    final starting = _starting;
    if (starting != null) {
      return starting.then((_) {
        if (!_active && !_disposed) return start();
      });
    }
    if (_active) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    _active = true;
    final lifecycle = _lifecycle;
    if (!_loaded) {
      final destinationGeneration = _generation;
      final record = await _journeyStore.load();
      if (!_active || _disposed || lifecycle != _lifecycle) return;
      _trail.addAll(record.points);
      _trailBreaks.addAll(record.breakIndices);
      _walkedMeters = record.walkedMeters;
      if (_generation == destinationGeneration) {
        _destination = record.destination;
        _destinationName = record.destinationName;
      }
      _loaded = true;
    }
    try {
      await _locationSource.ensureAvailable();
      if (!_active || _disposed || lifecycle != _lifecycle) return;
      _headingSubscription = _compassService.heading.listen(
        _onHeading,
        onError: (Object _) {
          _heading = null;
          _emitNavigation();
        },
      );
      _gpsSubscription = _locationSource.fixes.listen(
        _onFix,
        onError: (Object _) {
          _publish(
            NavigationStatus.error,
            'Không nhận được GPS. Hãy kiểm tra quyền và dịch vụ vị trí.',
            urgent: true,
          );
        },
      );
      _timer = Timer.periodic(checkInterval, (_) {
        if (!_hasUsableFix) {
          _publish(
            NavigationStatus.poorGps,
            'Vị trí GPS chưa đủ chính xác hoặc đã cũ. Hãy chờ tín hiệu.',
            urgent: true,
          );
          unawaited(_pollCurrentFix());
        } else {
          _emitNavigation();
          if (_destination != null &&
              !_arrived &&
              (_lastRequestAt == null ||
                  _now().difference(_lastRequestAt!) >= refreshInterval) &&
              (_tracker == null ||
                  _plannedFrom!.distanceTo(_fix!.point) >= 5 ||
                  _routeError != null)) {
            unawaited(refresh());
          }
        }
      });
      _publish(NavigationStatus.locating, 'Đang tìm vị trí GPS...');
      // The stream may produce a newer fix before the one-shot call completes.
      final fix = await _locationSource.current();
      if (_active && !_disposed && lifecycle == _lifecycle) _onFix(fix);
    } catch (error) {
      if (!_active || _disposed || lifecycle != _lifecycle) return;
      _publish(
        NavigationStatus.error,
        error.toString().replaceFirst('Exception: ', ''),
        urgent: true,
      );
      if (_gpsSubscription == null) _active = false;
    }
  }

  bool get _hasUsableFix =>
      _fix != null &&
      _fix!.accuracy.isFinite &&
      _fix!.accuracy > 0 &&
      _fix!.accuracy <= 25 &&
      _now().difference(_fix!.timestamp) <= AiConfig.gpsStaleAfter &&
      _fix!.timestamp.difference(_now()) <= const Duration(seconds: 3);

  Future<void> _pollCurrentFix() async {
    if (_pollingFix || !_active || _disposed) return;
    _pollingFix = true;
    final lifecycle = _lifecycle;
    try {
      final fix = await _locationSource.current();
      if (_active && !_disposed && lifecycle == _lifecycle) _onFix(fix);
    } catch (_) {
      // The existing poor-GPS state remains visible and spoken; retry at next tick.
    } finally {
      _pollingFix = false;
    }
  }

  void _onHeading(double heading) {
    if (!_active || !heading.isFinite) return;
    // Circular smoothing correctly averages headings around north (359°/1°).
    if (_heading == null) {
      _heading = (heading + 360) % 360;
    } else {
      final delta = ((heading - _heading! + 180) % 360) - 180;
      _heading = (_heading! + delta * 0.25 + 360) % 360;
    }
    _headingAt = _now();
    final previousPublished = _snapshot.headingDegrees;
    final delta = previousPublished == null
        ? 360.0
        : ((_heading! - previousPublished + 180) % 360 - 180).abs();
    if (delta < 3 &&
        _headingPublishedAt != null &&
        _now().difference(_headingPublishedAt!) < const Duration(seconds: 1)) {
      return;
    }
    _headingPublishedAt = _now();
    _emitNavigation();
  }

  void _onFix(NavigationFix fix) {
    if (!_active ||
        _disposed ||
        !fix.point.lat.isFinite ||
        !fix.point.lng.isFinite ||
        fix.point.lat.abs() > 90 ||
        fix.point.lng.abs() > 180 ||
        (_fix != null && !fix.timestamp.isAfter(_fix!.timestamp))) {
      return;
    }
    final previousFix = _fix;
    if (previousFix != null &&
        fix.accuracy <= 25 &&
        previousFix.accuracy <= 25) {
      final seconds =
          fix.timestamp.difference(previousFix.timestamp).inMilliseconds / 1000;
      if (seconds < 120 &&
          fix.point.distanceTo(previousFix.point) >
              math.max(15, seconds * 4 + fix.accuracy + previousFix.accuracy)) {
        _publish(
          NavigationStatus.poorGps,
          'GPS thay đổi bất thường. Đang kiểm tra lại vị trí.',
          urgent: true,
        );
        return;
      }
    }
    _fix = fix;
    if (!_hasUsableFix) {
      _arrivalFixes = 0;
      _offRouteFixes = 0;
      _publish(
        NavigationStatus.poorGps,
        'GPS có sai số lớn. Tạm chờ trước khi chỉ hướng.',
        urgent: true,
      );
      return;
    }
    _recordTrail(fix);
    final tracker = _tracker;
    if (tracker != null && !_arrived) {
      final match = tracker.update(fix.point, fix.accuracy);
      final offRoute =
          match.crossTrackMeters > math.max(12, fix.accuracy * 1.8);
      _offRouteFixes = offRoute ? _offRouteFixes + 1 : 0;
      if (!offRoute) _match = match;
      final tolerance = fix.accuracy.clamp(5.0, 12.0);
      final nearEnd =
          !offRoute &&
          tracker.route.lengthMeters - match.alongMeters <= tolerance &&
          fix.point.distanceTo(_destination!) <= tolerance;
      _arrivalFixes = nearEnd ? _arrivalFixes + 1 : 0;
      if (_arrivalFixes >= 3) {
        _arrived = true;
        unawaited(_save());
      }
      if (_offRouteFixes >= 3 &&
          (_lastRequestAt == null ||
              _now().difference(_lastRequestAt!) >=
                  const Duration(seconds: 10))) {
        unawaited(refresh());
      }
    }
    _emitNavigation();
    if (_destination != null &&
        _tracker == null &&
        !_arrived &&
        _planningGeneration == null &&
        (_lastRequestAt == null ||
            _now().difference(_lastRequestAt!) >=
                const Duration(seconds: 10))) {
      unawaited(refresh());
    }
  }

  void _recordTrail(NavigationFix fix) {
    final previous = _lastRecordedFix;
    if (previous != null) {
      final seconds =
          fix.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
      final distance = previous.point.distanceTo(fix.point);
      if (seconds > 120) {
        // Do not join two walks separated by a pause or app restart.
        _trailBreaks.add(_trail.length);
      } else {
        if (distance < math.max(3, fix.accuracy * 0.5)) return;
        if (distance > math.max(15, seconds * 3.0)) return;
        _walkedMeters += distance;
      }
    } else if (_trail.isNotEmpty) {
      _trailBreaks.add(_trail.length);
    }
    _lastRecordedFix = fix;
    _trail.add(fix.point);
    if (_trail.length > 10000) {
      final removed = _trail.length - 10000;
      _trail.removeRange(0, removed);
      final retained = _trailBreaks
          .where((i) => i > removed)
          .map((i) => i - removed)
          .toList();
      _trailBreaks
        ..clear()
        ..addAll(retained);
    }
    if (_lastSaveAt == null ||
        _now().difference(_lastSaveAt!) >= const Duration(seconds: 5)) {
      unawaited(_save());
    }
  }

  @override
  Future<bool> setDestination(double lat, double lng, {String? name}) async {
    if (_disposed) return false;
    ++_generation;
    _planningGeneration = null;
    _destination = GeoPoint(lat, lng);
    _destinationName = name ?? 'Điểm đã chọn trên bản đồ';
    _tracker = null;
    _match = null;
    _arrived = false;
    _routeError = null;
    _lastRequestAt = null;
    _lastRouteAt = null;
    _snapshot = const RouteProgress();
    _offRouteFixes = _arrivalFixes = 0;
    unawaited(_save());
    if (!_hasUsableFix) {
      _publish(
        NavigationStatus.locating,
        'Đã chọn đích. Đang chờ GPS chính xác để tìm tuyến đi bộ.',
      );
      return false;
    }
    return _plan();
  }

  @override
  Future<void> refresh() async {
    if (!_active || _disposed || _destination == null || _arrived) return;
    if (!_hasUsableFix) {
      _publish(
        NavigationStatus.poorGps,
        'Chưa có GPS chính xác để cập nhật tuyến.',
        urgent: true,
      );
      return;
    }
    await _plan();
  }

  Future<bool> _plan() async {
    final generation = _generation;
    if (_planningGeneration == generation ||
        _destination == null ||
        !_hasUsableFix) {
      return false;
    }
    _planningGeneration = generation;
    _lastRequestAt = _now();
    final from = _fix!.point;
    final destination = _destination!;
    _publish(
      _offRouteFixes >= 3
          ? NavigationStatus.offRoute
          : NavigationStatus.planning,
      _offRouteFixes >= 3
          ? 'Bạn đang lệch tuyến. Đang tìm lại đường đi bộ.'
          : 'Đang cập nhật tuyến đi bộ...',
    );
    try {
      final route = await _planningService.plan(
        fromLat: from.lat,
        fromLng: from.lng,
        toLat: destination.lat,
        toLng: destination.lng,
      );
      if (_disposed || !_active || generation != _generation) return false;
      _tracker = RouteTracker(route);
      _match = _tracker!.update(_fix!.point, _fix!.accuracy);
      _plannedFrom = from;
      _lastRouteAt = _now();
      _routeError = null;
      _offRouteFixes = _arrivalFixes = 0;
      _emitNavigation();
      return true;
    } catch (error) {
      if (_disposed || !_active || generation != _generation) return false;
      _routeError = error is RoutePlanningException
          ? error.message
          : 'Không cập nhật được tuyến đi bộ.';
      _publish(
        NavigationStatus.error,
        '$_routeError${_tracker == null ? '' : ' Đang giữ tuyến đã tải trước đó.'}',
        urgent: true,
      );
      return false;
    } finally {
      if (_planningGeneration == generation) _planningGeneration = null;
    }
  }

  void _emitNavigation() {
    if (!_active || _disposed) return;
    if (!_hasUsableFix) return;
    if (_arrived) {
      _publish(
        NavigationStatus.arrived,
        'Đã đến ${_destinationName ?? 'nơi'} .',
        key: 'arrived',
      );
      return;
    }
    if (_tracker == null || _match == null) {
      if (_planningGeneration == _generation) return;
      _publish(
        _routeError == null ? NavigationStatus.idle : NavigationStatus.error,
        _routeError ??
            'Đã tìm thấy vị trí. Hãy chọn điểm đến hoặc nói “đi đến ...”.',
      );
      return;
    }
    if (_offRouteFixes >= 3) {
      _publish(
        NavigationStatus.offRoute,
        'Bạn đang lệch tuyến. Đang chờ cập nhật đường đi bộ.',
        urgent: true,
      );
      return;
    }
    final route = _tracker!.route;
    final along = _match!.alongMeters;
    var index = 0;
    while (index + 1 < route.waypoints.length &&
        route.cumulativeMeters[route.waypoints[index + 1].shapeIndex] <=
            along) {
      index++;
    }
    final nextIndex = math.min(index + 1, route.waypoints.length - 1);
    final next = route.waypoints[nextIndex];
    final toNext = math.max(
      0.0,
      route.cumulativeMeters[next.shapeIndex] - along,
    );
    final remaining = math.max(0.0, route.lengthMeters - along);
    final lookAhead = (_fix!.speed * 4 + _fix!.accuracy).clamp(6.0, 18.0);
    final targetMeters = toNext > 2
        ? math.min(along + lookAhead, route.cumulativeMeters[next.shapeIndex])
        : along + lookAhead;
    final target = _tracker!.pointAt(targetMeters);
    // Bearing from the matched path point follows the road instead of cutting across it.
    final bearing = _match!.point.bearingTo(target);
    final heading = _freshHeading;
    final facing = heading == null ? null : facingInstruction(heading, bearing);
    final approaching =
        toNext <= math.max(10, _fix!.speed * 8 + _fix!.accuracy);
    final street = route.waypoints[index].streetName;
    String message;
    String phase;
    if (remaining < 3 && _fix!.point.distanceTo(_destination!) > 12) {
      message =
          'Đã tới cuối lối đi trên bản đồ. Đích còn khoảng ${_fix!.point.distanceTo(_destination!).round()} mét.';
      phase = 'path-end';
    } else if (heading == null) {
      message =
          'Chưa xác định được hướng điện thoại. ${approaching ? 'Còn ${toNext.round()} mét: ${next.instruction}.' : 'Tuyến còn ${remaining.round()} mét.'}';
      phase = 'no-heading';
    } else if (facing != 'Đi thẳng') {
      message =
          '$facing để theo lối đi${street.isEmpty ? '' : ' $street'}. Tuyến còn ${remaining.round()} mét.';
      phase = facing!;
    } else if (approaching && next.type != 'arrive') {
      message = 'Sau ${toNext.round()} mét, ${next.instruction.toLowerCase()}.';
      phase = 'approaching';
    } else {
      message =
          'Đi tiếp${street.isEmpty ? '' : ' trên $street'}. ${next.type == 'arrive' ? 'Còn ${remaining.round()} mét tới đích.' : 'Sau ${toNext.round()} mét, ${next.instruction.toLowerCase()}.'}';
      phase = 'continue';
    }
    if (_routeError != null) message = 'Tuyến chưa cập nhật được. $message';
    _publish(
      _routeError == null
          ? NavigationStatus.navigating
          : NavigationStatus.error,
      message,
      index: index,
      bearing: bearing,
      remaining: remaining,
      street: street,
      key:
          '${next.lat.toStringAsFixed(5)},${next.lng.toStringAsFixed(5)}:$phase',
    );
  }

  double? get _freshHeading =>
      _headingAt != null &&
          _now().difference(_headingAt!) < const Duration(seconds: 10)
      ? _heading
      : null;

  void _publish(
    NavigationStatus status,
    String message, {
    int index = 0,
    double? bearing,
    double? remaining,
    String street = '',
    String? key,
    bool urgent = false,
  }) {
    if (_disposed) return;
    _snapshot = RouteProgress(
      position: _fix?.point,
      headingDegrees: _freshHeading,
      targetBearing: bearing,
      accuracyMeters: _fix?.accuracy,
      walkedMeters: _walkedMeters,
      remainingMeters: remaining ?? (_arrived ? 0 : _snapshot.remainingMeters),
      waypoints: _tracker?.route.waypoints ?? const [],
      currentIndex: index,
      remainingPath: _arrived
          ? const []
          : (_tracker != null && _match != null
                ? _tracker!.remainingGeometry(_match!)
                : const []),
      walkedPath: List.unmodifiable(_trail),
      trailBreakIndices: List.unmodifiable(_trailBreaks),
      destination: _destination,
      destinationName: _destinationName,
      status: status,
      message: message,
      updatedAt: _fix?.timestamp,
      lastRouteUpdate: _lastRouteAt,
      streetName: street,
      crossTrackMeters: _match?.crossTrackMeters ?? 0,
    );
    _progress.add(_snapshot);
    _instructions.add(
      RouteInstruction(
        text: message,
        remainingMeters: _snapshot.remainingMeters,
        key: key ?? status.name,
        urgent: urgent,
      ),
    );
  }

  Future<void> _save() async {
    _lastSaveAt = _now();
    try {
      await _journeyStore.save(
        JourneyRecord(
          points: List.of(_trail),
          breakIndices: List.of(_trailBreaks),
          walkedMeters: _walkedMeters,
          destination: _arrived ? null : _destination,
          destinationName: _arrived ? null : _destinationName,
        ),
      );
    } catch (_) {
      if (!_disposed) {
        _publish(
          NavigationStatus.error,
          'Không lưu được hành trình trên thiết bị.',
        );
      }
    }
  }

  @override
  void cancelDestination() {
    ++_generation;
    _destination = null;
    _destinationName = null;
    _tracker = null;
    _match = null;
    _routeError = null;
    _arrived = false;
    _snapshot = const RouteProgress();
    unawaited(_save());
    _emitNavigation();
  }

  @override
  Future<void> clearJourney() async {
    _trail.clear();
    _trailBreaks.clear();
    _walkedMeters = 0;
    _lastRecordedFix = null;
    await _save();
    _emitNavigation();
  }

  @override
  void stop() {
    _active = false;
    ++_lifecycle;
    ++_generation;
    _planningGeneration = null;
    _timer?.cancel();
    _gpsSubscription?.cancel();
    _headingSubscription?.cancel();
    _gpsSubscription = null;
    _headingSubscription = null;
    _lastRecordedFix = null;
    _heading = null;
    _publish(NavigationStatus.paused, 'Dẫn đường đã tạm dừng.');
    unawaited(_save());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    stop();
    _disposed = true;
    await _save();
    _planningService.dispose();
    await _instructions.close();
    await _progress.close();
  }
}
