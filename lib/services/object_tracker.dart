import 'dart:math' as math;
import '../models/detection_result.dart';

class _Track {
  _Track(this.object, this.firstAt, this.at, this.height);
  DetectedObject object;
  final DateTime firstAt;
  DateTime at;
  double height;
  int hits = 1;
}

/// Conservative class-aware IoU association. No extrapolated/ghost boxes are
/// emitted: a missed frame breaks consecutive confirmation immediately.
class ObjectTracker {
  ObjectTracker({this.ttl = const Duration(seconds: 5), this.minIou = .25});
  final Duration ttl;
  final double minIou;
  final Map<int, _Track> _tracks = {};
  int _nextId = 1;
  String? _source;
  DateTime? _lastAt;

  void reset() {
    _tracks.clear();
    _source = null;
    _lastAt = null;
    // Never reuse an ID in a session, including after camera/model reset.
  }

  List<DetectedObject> update(
    DetectionResult result,
    DateTime at,
    DateTime now, {
    required String source,
  }) {
    final key = '$source:${result.imageWidth}x${result.imageHeight}';
    if (key != _source) {
      reset();
      _source = key;
    }
    if (at.isAfter(now) ||
        now.difference(at) > ttl ||
        (_lastAt != null && !at.isAfter(_lastAt!))) {
      return const [];
    }
    _lastAt = at;
    _tracks.removeWhere((id, track) => at.difference(track.at) > ttl);
    final remaining = _tracks.keys.toSet();
    final detections =
        result.objects
            .where(
              (o) =>
                  o.confidence.isFinite &&
                  o.confidence >= 0 &&
                  o.confidence <= 1 &&
                  [
                    o.x1,
                    o.x2,
                    o.y1,
                    o.y2,
                    o.areaRatio,
                  ].every((v) => v.isFinite) &&
                  o.x1 >= 0 &&
                  o.y1 >= 0 &&
                  o.x2 > o.x1 &&
                  o.y2 > o.y1 &&
                  o.x2 <= result.imageWidth &&
                  o.y2 <= result.imageHeight &&
                  ['left', 'center', 'right'].contains(o.position),
            )
            .toList()
          ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final output = <DetectedObject>[];
    for (final object in detections) {
      int? match;
      var overlap = minIou;
      for (final id in remaining) {
        final old = _tracks[id]!;
        if (old.object.className != object.className) continue;
        final score = _iou(old.object, object);
        if (score >= overlap) {
          overlap = score;
          match = id;
        }
      }
      final height = (object.y2 - object.y1) / result.imageHeight;
      double? growth;
      if (match != null) {
        remaining.remove(match);
        final old = _tracks[match]!;
        final seconds = at.difference(old.at).inMicroseconds / 1000000;
        if (seconds > 0 && old.hits >= 2 && old.height > 0) {
          growth = math.log(height / old.height) / seconds;
        }
        old.hits++;
        old.at = at;
        old.height = height;
        old.object = object;
      } else {
        match = _nextId++;
        _tracks[match] = _Track(object, at, at, height);
      }
      final track = _tracks[match]!;
      output.add(
        object.withTrack(
          id: match,
          at: at,
          firstAt: track.firstAt,
          hits: track.hits,
          heightGrowth: growth,
        ),
      );
    }
    for (final id in remaining) {
      _tracks[id]!.hits = 0;
    }
    return List.unmodifiable(output);
  }

  double _iou(DetectedObject a, DetectedObject b) {
    final area =
        math.max(0.0, math.min(a.x2, b.x2) - math.max(a.x1, b.x1)) *
        math.max(0.0, math.min(a.y2, b.y2) - math.max(a.y1, b.y1));
    return area /
        ((a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - area);
  }
}
