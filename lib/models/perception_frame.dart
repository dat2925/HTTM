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
  });

  final List<DetectedObject> objects;
  final int imageWidth;
  final int imageHeight;
  final double fps;
  final int latencyMs;
}
