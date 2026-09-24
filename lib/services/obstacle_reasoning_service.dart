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
      ..sort((a, b) => _priority(b).compareTo(_priority(a)));
    final selected = ranked.first;
    final name = _vietnameseNames[selected.className] ?? 'vật cản';

    final text = switch ((selected.position, selected.danger)) {
      ('center', DangerLevel.high) => 'Cảnh báo. Có $name rất gần phía trước.',
      ('center', DangerLevel.medium) => 'Phía trước có $name.',
      ('left', DangerLevel.high) => 'Có $name gần bên trái.',
      ('right', DangerLevel.high) => 'Có $name gần bên phải.',
      ('left', _) => 'Có $name bên trái.',
      ('right', _) => 'Có $name bên phải.',
      _ => 'Phía trước có $name.',
    };

    return ObstacleWarning(
      text: text,
      danger: selected.danger,
      object: selected,
    );
  }

  int _priority(DetectedObject object) {
    final centerBonus = object.position == 'center' ? 2 : 0;
    return object.danger.score + centerBonus;
  }
}
