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
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.trackId,
    this.observedAt,
    this.firstSeenAt,
    this.consecutiveHits = 1,
    this.heightGrowthPerSecond,
  });

  final String className;
  final double confidence;
  final String position;
  final DangerLevel danger;
  final double areaRatio;
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final int? trackId;
  final DateTime? observedAt, firstSeenAt;
  final int consecutiveHits;

  /// Rate of ln(normalized box height), not speed/depth/time to collision.
  final double? heightGrowthPerSecond;
  bool get isStable => consecutiveHits >= 2;

  DetectedObject withTrack({
    required int id,
    required DateTime at,
    required DateTime firstAt,
    required int hits,
    double? heightGrowth,
  }) => DetectedObject(
    className: className,
    confidence: confidence,
    position: position,
    danger: danger,
    areaRatio: areaRatio,
    x1: x1,
    y1: y1,
    x2: x2,
    y2: y2,
    trackId: id,
    observedAt: at,
    firstSeenAt: firstAt,
    consecutiveHits: hits,
    heightGrowthPerSecond: heightGrowth,
  );

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
      x1: (json['x1'] as num?)?.toDouble() ?? 0,
      y1: (json['y1'] as num?)?.toDouble() ?? 0,
      x2: (json['x2'] as num?)?.toDouble() ?? 0,
      y2: (json['y2'] as num?)?.toDouble() ?? 0,
    );
  }
}

class DetectionResult {
  const DetectionResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.objects,
    this.model,
    this.runtime,
    this.inferenceMs,
  });

  final int imageWidth;
  final int imageHeight;
  final List<DetectedObject> objects;
  final String? model;
  final String? runtime;
  final double? inferenceMs;

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
      model: (json['diagnostics'] as Map?)?['model'] as String?,
      runtime: (json['diagnostics'] as Map?)?['runtime'] as String?,
      inferenceMs: ((json['diagnostics'] as Map?)?['inference_ms'] as num?)
          ?.toDouble(),
      objects: rawObjects
          .whereType<Map<String, dynamic>>()
          .map(DetectedObject.fromJson)
          .toList(growable: false),
    );
  }
}
