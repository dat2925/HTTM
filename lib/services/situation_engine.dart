import '../models/detection_result.dart';
import '../models/geo_point.dart';
import '../models/route_progress.dart';
import '../models/situation_context.dart';
import 'obstacle_reasoning_service.dart';

/// Local aggregation only. Sampling this engine never starts network work.
class SituationEngine {
  static const detectionTtl = Duration(seconds: 5);
  static const imageTtl = Duration(seconds: 10);
  final _reasoning = ObstacleReasoningService();
  List<DetectedObject> _objects = const [];
  DateTime? _detectionAt;
  String _scene = '', _candidateScene = '';
  int _sceneSamples = 0, _revision = 0;
  RouteProgress? _previousRoute;
  Map<String, bool>? _previousSources;
  final List<SituationEvent> _events = [];
  String? _watchCategory;
  DateTime? _watchUntil;

  void watch(String? category, DateTime now) {
    _watchCategory = category;
    _watchUntil = category == null ? null : now.add(const Duration(minutes: 2));
    _events.removeWhere((e) => e.kind == 'watchMatch');
  }

  void sensorUnavailable(DateTime now) {
    clearPerception();
    _add('sensorLost', 'lost:yolo', 2, now, const Duration(seconds: 30));
  }

  static bool fresh(DateTime? at, DateTime now, Duration ttl) =>
      at != null &&
      !at.isAfter(now.add(const Duration(seconds: 2))) &&
      now.difference(at) <= ttl;

  void observeDetections(
    List<DetectedObject> objects,
    DateTime capturedAt,
    DateTime now,
  ) {
    if (!fresh(capturedAt, now, detectionTtl) ||
        (_detectionAt != null && !capturedAt.isAfter(_detectionAt!))) {
      return;
    }
    _objects = List.unmodifiable(
      objects.where(
        (o) =>
            o.confidence >= .35 &&
            o.confidence.isFinite &&
            const ['left', 'center', 'right'].contains(o.position),
      ),
    );
    _detectionAt = capturedAt;
    final counts = <String, int>{};
    for (final o in _objects) {
      counts.update(
        '${o.className}:${o.position}',
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
    final keys =
        counts.entries.map((e) => '${e.key}:${e.value.clamp(1, 3)}').toList()
          ..sort();
    final key = keys.join('|');
    if (_candidateScene != key) {
      _revision++;
      _events.removeWhere(
        (e) => e.kind == 'obstacle' || e.kind == 'sceneChanged',
      );
    }
    if (_candidateScene == key) {
      _sceneSamples++;
    } else {
      _candidateScene = key;
      _sceneSamples = 1;
    }
    // Invalidate answers immediately; proactive observations require two samples.
    if (key != _scene) {
      if (_sceneSamples >= 2) {
        final kind = _objects.any((o) => o.position == 'center')
            ? 'obstacle'
            : 'sceneChanged';
        if (_objects.isNotEmpty) {
          _add(
            kind,
            '$kind:$key',
            kind == 'obstacle' ? 2 : 1,
            now,
            detectionTtl,
          );
        }
        _scene = key;
      }
    }
    // A stable scene renews its pending event evidence, but not its dedupe identity.
    for (var i = 0; i < _events.length; i++) {
      final e = _events[i];
      if ((e.kind == 'obstacle' || e.kind == 'sceneChanged') && key == _scene) {
        _events[i] = SituationEvent(
          kind: e.kind,
          key: e.key,
          priority: e.priority,
          createdAt: e.createdAt,
          expiresAt: capturedAt.add(detectionTtl),
        );
      }
    }
  }

  void clearPerception() {
    if (_detectionAt == null && _objects.isEmpty && _scene.isEmpty) return;
    _objects = const [];
    _detectionAt = null;
    _scene = _candidateScene = '';
    _sceneSamples = 0;
    _events.removeWhere(
      (e) =>
          e.kind == 'obstacle' ||
          e.kind == 'sceneChanged' ||
          e.kind == 'watchMatch',
    );
    _revision++;
  }

  void _add(String kind, String key, int priority, DateTime now, Duration ttl) {
    _events.removeWhere((e) => e.key == key);
    _events.add(
      SituationEvent(
        kind: kind,
        key: key,
        priority: priority,
        createdAt: now,
        expiresAt: now.add(ttl),
      ),
    );
    if (_events.length > 30) _events.removeAt(0);
  }

  SituationContext snapshot(
    RouteProgress p,
    DateTime now, {
    DateTime? imageAt,
  }) {
    final gps =
        fresh(p.updatedAt, now, const Duration(seconds: 15)) &&
        p.position != null &&
        p.accuracyMeters != null &&
        p.accuracyMeters! > 0 &&
        p.accuracyMeters! <= 25 &&
        p.status != NavigationStatus.poorGps;
    final sources = {
      'gps': gps,
      'heading':
          p.headingDegrees != null &&
          fresh(p.headingUpdatedAt, now, const Duration(seconds: 10)),
      'yolo': fresh(_detectionAt, now, detectionTtl),
      'camera': fresh(imageAt, now, imageTtl),
      'navigation':
          gps &&
          p.status == NavigationStatus.navigating &&
          p.destination != null,
    };
    final previous = _previousRoute;
    if (_watchUntil != null && !now.isBefore(_watchUntil!)) watch(null, now);
    final watching =
        sources['yolo']! &&
        _watchCategory != null &&
        _sceneSamples >= 2 &&
        _objects.any(
          (o) =>
              o.position == 'center' &&
              (_watchCategory == 'all' ||
                  ObstacleReasoningService.category(o.className) ==
                      _watchCategory),
        );
    if (watching) {
      final key = 'watch:$_watchCategory:$_scene';
      final existing = _events.where((e) => e.key == key).firstOrNull;
      _events.removeWhere((e) => e.kind == 'watchMatch');
      _events.add(
        SituationEvent(
          kind: 'watchMatch',
          key: key,
          priority: 3,
          createdAt: existing?.createdAt ?? now,
          expiresAt: _detectionAt!.add(detectionTtl),
        ),
      );
    } else {
      _events.removeWhere((e) => e.kind == 'watchMatch');
    }
    if (previous != null) {
      if (previous.status != p.status ||
          previous.currentIndex != p.currentIndex ||
          previous.lastRouteUpdate != p.lastRouteUpdate ||
          previous.destination?.lat != p.destination?.lat ||
          previous.destination?.lng != p.destination?.lng) {
        _revision++;
      }
      if (p.lastRouteUpdate != null &&
          p.lastRouteUpdate != previous.lastRouteUpdate &&
          _routeKey(p) != _routeKey(previous)) {
        _events.removeWhere(
          (e) => e.kind == 'routeChanged' || e.kind == 'maneuver',
        );
        _add(
          'routeChanged',
          'route:${p.lastRouteUpdate!.toIso8601String()}',
          1,
          now,
          const Duration(seconds: 30),
        );
      }
    }
    if (_previousSources != null) {
      for (final source in ['gps', 'heading', 'yolo']) {
        if (_previousSources![source] == sources[source]) continue;
        _revision++;
        if (sources[source] == false) {
          _add(
            source == 'heading' ? 'headingUnavailable' : 'sensorLost',
            'lost:$source',
            2,
            now,
            const Duration(seconds: 30),
          );
        } else if (source == 'gps') {
          _add(
            'gpsRecovered',
            'gpsRecovered',
            1,
            now,
            const Duration(seconds: 30),
          );
        }
      }
    }
    // Remove events whose condition has recovered or changed, even during cooldown.
    _events.removeWhere(
      (e) =>
          (e.key == 'lost:gps' && gps) ||
          (e.key == 'lost:yolo' && sources['yolo']!) ||
          (e.key == 'lost:heading' && sources['heading']!) ||
          (e.kind == 'gpsRecovered' && !gps) ||
          (e.kind == 'maneuver' &&
              (!sources['navigation']! ||
                  !e.key.endsWith(':${p.currentIndex}'))),
    );
    double? maneuverMeters;
    if (sources['navigation']! && p.currentIndex < p.waypoints.length) {
      final w = p.waypoints[p.currentIndex];
      maneuverMeters = p.position!.distanceTo(GeoPoint(w.lat, w.lng));
      if (maneuverMeters <= 30 &&
          const [
            'turn',
            'crossing',
            'crosswalk',
            'intersection',
          ].contains(w.type)) {
        final key = 'maneuver:${p.lastRouteUpdate}:${p.currentIndex}';
        if (!_events.any((e) => e.key == key)) {
          _add('maneuver', key, 1, now, const Duration(seconds: 20));
        }
      }
    }
    _previousRoute = p;
    _previousSources = sources;
    _events.removeWhere((e) => !e.expiresAt.isAfter(now));
    final objects = sources['yolo']! ? _objects : <DetectedObject>[];
    return SituationContext(
      timestamp: now,
      revision: _revision,
      navigation: p,
      detections: objects,
      sourceFreshness: Map.unmodifiable(sources),
      observations: _reasoning.summarize(objects),
      uncertainty: [
        if (!gps)
          'Vị trí GPS thiếu, cũ hoặc sai số lớn; chưa dùng để xác định vị trí chính xác.',
        if (!sources['yolo']!) 'Chưa có nhận diện camera còn mới.',
        if (!sources['heading']!) 'Chưa có hướng la bàn còn mới.',
        'Chưa đo độ sâu, vận tốc hay khoảng trống; vị trí đối tượng chỉ thuộc khung hình.',
        if (sources['navigation']!)
          'Chưa đăng ký hình học camera với tuyến; không xác định vật thể nằm trên tuyến.',
      ],
      events: List.unmodifiable(_events),
      yoloAt: sources['yolo']! ? _detectionAt : null,
      imageAt: sources['camera']! ? imageAt : null,
      maneuverMeters: maneuverMeters,
      watchCategory: _watchCategory,
    );
  }

  String _routeKey(RouteProgress p) =>
      '${p.destination?.lat}:${p.destination?.lng}:'
      '${p.waypoints.skip(p.currentIndex).where((w) => !w.instruction.startsWith('Bắt đầu')).map((w) => '${w.lat.toStringAsFixed(4)}:${w.lng.toStringAsFixed(4)}:${w.instruction}').join('|')}';
}
