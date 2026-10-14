import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../models/detection_result.dart';
import '../models/perception_frame.dart';

/// Camera preview with the YOLO box overlay, the Trái|Giữa|Phải divider
/// lines, and an FPS/latency readout. Purely a read-only view over a
/// [Stream<PerceptionFrame>] — it owns neither the camera nor the model, so
/// it can be driven by a fake stream while building the UI.
class PerceptionPreview extends StatelessWidget {
  const PerceptionPreview({
    super.key,
    required this.controller,
    required this.frames,
  });

  final CameraController? controller;
  final Stream<PerceptionFrame> frames;

  @override
  Widget build(BuildContext context) {
    final camera = controller;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (camera != null && camera.value.isInitialized)
            CameraPreview(camera)
          else
            const Center(child: CircularProgressIndicator()),
          StreamBuilder<PerceptionFrame>(
            stream: frames,
            builder: (context, snapshot) {
              final frame = snapshot.data;
              return CustomPaint(
                painter: _OverlayPainter(frame: frame),
              );
            },
          ),
          Positioned(
            top: 8,
            right: 8,
            child: StreamBuilder<PerceptionFrame>(
              stream: frames,
              builder: (context, snapshot) {
                final frame = snapshot.data;
                if (frame == null) return const SizedBox.shrink();
                return _ReadoutBadge(
                  text:
                      '${frame.fps.toStringAsFixed(1)} FPS · '
                      '${frame.latencyMs} ms',
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadoutBadge extends StatelessWidget {
  const _ReadoutBadge({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({required this.frame});

  final PerceptionFrame? frame;

  @override
  void paint(Canvas canvas, Size size) {
    final dividerPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      dividerPaint,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      dividerPaint,
    );

    final frame = this.frame;
    if (frame == null || frame.imageWidth == 0 || frame.imageHeight == 0) {
      return;
    }
    final scaleX = size.width / frame.imageWidth;
    final scaleY = size.height / frame.imageHeight;

    for (final object in frame.objects) {
      final box = _rectFor(object, scaleX, scaleY);
      final paint = Paint()
        ..color = _colorFor(object.danger)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3;
      canvas.drawRect(box, paint);
      _drawLabel(canvas, box.topLeft, object.className, paint.color);
    }
  }

  Rect _rectFor(DetectedObject object, double scaleX, double scaleY) {
    return Rect.fromLTRB(
      object.x1 * scaleX,
      object.y1 * scaleY,
      object.x2 * scaleX,
      object.y2 * scaleY,
    );
  }

  void _drawLabel(Canvas canvas, Offset origin, String text, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          backgroundColor: Colors.black54,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, origin.translate(0, -painter.height));
  }

  Color _colorFor(DangerLevel danger) => switch (danger) {
    DangerLevel.high => Colors.redAccent,
    DangerLevel.medium => Colors.orangeAccent,
    DangerLevel.low => Colors.greenAccent,
  };

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) =>
      oldDelegate.frame != frame;
}
