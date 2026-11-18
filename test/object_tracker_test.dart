import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/models/detection_result.dart';
import 'package:smart_navigation/services/object_tracker.dart';

DetectedObject box({String name = 'pole', double x = 10, double bottom = 70}) =>
    DetectedObject(
      className: name,
      confidence: .8,
      position: 'center',
      danger: DangerLevel.medium,
      areaRatio: .1,
      x1: x,
      y1: 10,
      x2: x + 20,
      y2: bottom,
    );
DetectionResult scene(List<DetectedObject> objects, {int width = 100}) =>
    DetectionResult(imageWidth: width, imageHeight: 100, objects: objects);

void main() {
  final start = DateTime.utc(2026, 11, 18);
  test('identity survives jitter, confirms twice, never emits ghosts', () {
    final tracker = ObjectTracker();
    List<DetectedObject> update(List<DetectedObject> objects, int ms) =>
        tracker.update(
          scene(objects),
          start.add(Duration(milliseconds: ms)),
          start.add(Duration(milliseconds: ms)),
          source: 'device:model',
        );
    final first = update([box()], 0).single;
    expect(first.isStable, isFalse);
    final second = update([box(x: 11)], 500).single;
    expect(second.trackId, first.trackId);
    expect(second.isStable, isTrue);
    expect(second.firstSeenAt, start);
    expect(update([], 1000), isEmpty);
    final back = update([box()], 1500).single;
    expect(back.trackId, first.trackId);
    expect(back.isStable, isFalse);
    expect(update([box()], 2000).single.isStable, isTrue);
  });
  test(
    'class, model, geometry, expiry and reset prevent old identity reuse',
    () {
      final tracker = ObjectTracker();
      var at = start;
      int next(String source, {String name = 'pole', int width = 100}) {
        at = at.add(const Duration(milliseconds: 500));
        return tracker
            .update(
              scene([box(name: name)], width: width),
              at,
              at,
              source: source,
            )
            .single
            .trackId!;
      }

      final a = next('device:n');
      expect(next('device:n', name: 'tree'), isNot(a));
      final b = next('server:n');
      expect(b, isNot(a));
      final c = next('server:n', width: 200);
      expect(c, isNot(b));
      at = at.add(const Duration(seconds: 6));
      final d = next('server:n', width: 200);
      expect(d, isNot(c));
      tracker.reset();
      expect(next('server:n', width: 200), isNot(d));
    },
  );
  test(
    'one-to-one matching, stale/future/order rejection, growth observation',
    () {
      final tracker = ObjectTracker();
      final a = tracker.update(
        scene([box(), box(x: 60)]),
        start,
        start,
        source: 'a',
      );
      expect(a.map((o) => o.trackId).toSet(), hasLength(2));
      final at = start.add(const Duration(seconds: 1));
      final b = tracker
          .update(scene([box(bottom: 75)]), at, at, source: 'a')
          .single;
      expect(b.trackId, a.first.trackId);
      final t = at.add(const Duration(seconds: 1));
      expect(
        tracker
            .update(scene([box(bottom: 80)]), t, t, source: 'a')
            .single
            .heightGrowthPerSecond,
        greaterThan(0),
      );
      expect(tracker.update(scene([box()]), at, t, source: 'a'), isEmpty);
      expect(
        tracker.update(
          scene([box()]),
          t.add(const Duration(seconds: 1)),
          t,
          source: 'a',
        ),
        isEmpty,
      );
      expect(
        tracker.update(
          scene([box()]),
          t,
          t.add(const Duration(seconds: 6)),
          source: 'a',
        ),
        isEmpty,
      );
    },
  );
}
