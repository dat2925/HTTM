enum DangerLevel { low, medium, high }

extension DangerLevelX on DangerLevel {
  int get score => switch (this) {
    DangerLevel.high => 3,
    DangerLevel.medium => 2,
    DangerLevel.low => 1,
  };

  String get label => switch (this) {
    DangerLevel.high => 'Cao',
    DangerLevel.medium => 'Trung bình',
    DangerLevel.low => 'Thấp',
  };
}

class DetectedObject {
  const DetectedObject({
    required this.className,
    required this.confidence,
    required this.position,
    required this.danger,
    required this.areaRatio,
  });

  final String className;
  final double confidence;
  final String position;
  final DangerLevel danger;
  final double areaRatio;

  factory DetectedObject.fromJson(Map<String, dynamic> json) {
    final dangerText = json['danger']?.toString().toLowerCase();
    return DetectedObject(
      className: json['class_name']?.toString() ?? 'object',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      position: json['position']?.toString().toLowerCase() ?? 'center',
      danger: switch (dangerText) {
        'high' => DangerLevel.high,
        'medium' => DangerLevel.medium,
        _ => DangerLevel.low,
      },
      areaRatio: (json['area_ratio'] as num?)?.toDouble() ?? 0,
    );
  }
}

class DetectionResult {
  const DetectionResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.objects,
  });

  final int imageWidth;
  final int imageHeight;
  final List<DetectedObject> objects;

  factory DetectionResult.fromJson(Map<String, dynamic> json) {
    if (json['success'] != true) {
      throw const FormatException('AI server returned an unsuccessful result.');
    }
    final rawObjects = json['objects'];
    if (rawObjects is! List) {
      throw const FormatException('Missing objects list.');
    }
    return DetectionResult(
      imageWidth: (json['image_width'] as num?)?.toInt() ?? 0,
      imageHeight: (json['image_height'] as num?)?.toInt() ?? 0,
      objects: rawObjects
          .whereType<Map<String, dynamic>>()
          .map(DetectedObject.fromJson)
          .toList(growable: false),
    );
  }
}
