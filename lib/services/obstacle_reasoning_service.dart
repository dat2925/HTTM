import '../models/detection_result.dart';

class ObstacleWarning {
  const ObstacleWarning({
    required this.text,
    required this.danger,
    required this.object,
  });

  final String text;
  final DangerLevel danger;
  final DetectedObject object;
}

class ObstacleReasoningService {
  static String category(String name) => switch (name) {
    'person' => 'person',
    'bicycle' || 'motorcycle' || 'car' || 'bus' || 'truck' => 'vehicle',
    'chair' || 'bench' || 'backpack' || 'suitcase' => 'obstacle',
    _ => 'other',
  };

  /// Counts and image regions are observable; distance and clearance are not.
  List<String> summarize(List<DetectedObject> objects) {
    final groups = <String, Map<String, int>>{};
    for (final object in objects) {
      final group = groups.putIfAbsent(object.position, () => {});
      group.update(object.className, (n) => n + 1, ifAbsent: () => 1);
    }
    return [
      for (final position in ['center', 'left', 'right'])
        if (groups[position] != null)
          '${switch (position) {
                'left' => 'Trái',
                'right' => 'Phải',
                _ => 'Giữa',
              }} khung hình: '
              '${(groups[position]!.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.value} ${_vietnameseNames[e.key] ?? 'đối tượng'}').join(', ')}.',
    ];
  }

  static const Map<String, String> _vietnameseNames = {
    'person': 'người',
    'bicycle': 'xe đạp',
    'motorcycle': 'xe máy',
    'car': 'ô tô',
    'bus': 'xe buýt',
    'truck': 'xe tải',
    'chair': 'ghế',
    'bench': 'ghế dài',
    'dog': 'chó',
    'backpack': 'ba lô',
    'suitcase': 'va li',
  };

  ObstacleWarning? selectWarning(List<DetectedObject> objects) {
    if (objects.isEmpty) return null;
    final ranked = List<DetectedObject>.of(objects)
      ..sort((a, b) {
        final priority = _priority(b).compareTo(_priority(a));
        return priority != 0 ? priority : a.className.compareTo(b.className);
      });
    final selected = ranked.first;
    final name = _vietnameseNames[selected.className] ?? 'vật cản';

    final base = switch ((selected.position, selected.danger)) {
      ('center', DangerLevel.high) =>
        'Camera ghi nhận $name ở giữa khung hình. Nên dừng lại kiểm tra.',
      ('center', DangerLevel.medium) =>
        'Camera ghi nhận $name ở giữa khung hình.',
      ('left', DangerLevel.high) => 'Camera ghi nhận $name bên trái.',
      ('right', DangerLevel.high) => 'Camera ghi nhận $name bên phải.',
      ('left', _) => 'Có $name bên trái.',
      ('right', _) => 'Có $name bên phải.',
      _ => 'Camera ghi nhận $name ở giữa khung hình.',
    };
    final regions = objects.map((o) => o.position).toSet().toList()..sort();
    final extra = objects.length > 1
        ? ' ${regions.length > 1 ? 'Có nhiều đối tượng ở ${regions.map((r) => switch (r) {
                  'left' => 'trái',
                  'right' => 'phải',
                  _ => 'giữa',
                }).join(', ')} khung hình.' : 'Có nhiều đối tượng trong vùng này.'}'
        : '';

    return ObstacleWarning(
      text: '$base$extra',
      danger: selected.danger,
      object: selected,
    );
  }

  int _priority(DetectedObject object) {
    final centerBonus = object.position == 'center' ? 2 : 0;
    return object.danger.score + centerBonus;
  }
}
