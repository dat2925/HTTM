import 'detection_result.dart';

/// One rendered detection cycle, consumed by [PerceptionPreview] to draw the
/// obstacle overlay and the FPS/latency readout.
class PerceptionFrame {
  const PerceptionFrame({
    required this.objects,
    required this.imageWidth,
    required this.imageHeight,
    required this.fps,
    required this.latencyMs,
    this.capturedAt,
    this.backend = 'unknown',
    this.model = 'unknown',
    this.runtime = 'unknown',
    this.inferenceMs,
    this.captureMs = 0,
    this.detectionMs = 0,
  });

  final List<DetectedObject> objects;
  final int imageWidth;
  final int imageHeight;
  final double fps;
  final int latencyMs;
  final DateTime? capturedAt;
  final String backend;
  final String model;
  final String runtime;
  final double? inferenceMs;
  final int captureMs;
  final int detectionMs;

  /// JSONL schema shared with the offline benchmark. No images or GPS.
  Map<String, Object?> toJson() => {
    'captured_at': capturedAt?.toUtc().toIso8601String(),
    'backend': backend,
    'model': model,
    'runtime': runtime,
    'fps': fps,
    'latency_ms': latencyMs,
    'capture_ms': captureMs,
    'detection_ms': detectionMs,
    'inference_ms': inferenceMs,
    'image_width': imageWidth,
    'image_height': imageHeight,
    'objects': [
      for (final o in objects)
        {
          'class_name': o.className,
          'confidence': o.confidence,
          'position': o.position,
          'track_id': o.trackId,
          'consecutive_hits': o.consecutiveHits,
          'observed_at': o.observedAt?.toUtc().toIso8601String(),
          'height_growth_per_second': o.heightGrowthPerSecond,
          'box': [o.x1, o.y1, o.x2, o.y2],
        },
    ],
  };
}
