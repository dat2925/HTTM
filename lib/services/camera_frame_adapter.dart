import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// A copied camera packet. Conversion/JPEG encoding runs on a worker isolate.
/// Never pass camera YUV planes to an API expecting an encoded image.
class CameraFramePacket {
  const CameraFramePacket({
    required this.width,
    required this.height,
    required this.planes,
    required this.rowStrides,
    required this.pixelStrides,
    required this.rotation,
    this.bgra = false,
  });
  final int width, height, rotation;
  final List<Uint8List> planes;
  final List<int> rowStrides, pixelStrides;
  final bool bgra;
}

Future<Uint8List> encodeCameraFrame(CameraFramePacket packet) =>
    compute(cameraFrameToJpeg, packet, debugLabel: 'camera-yuv-jpeg');

/// Full frame, no crop/resize/letterbox. Model runtime owns letterboxing and
/// returns boxes in the resulting upright JPEG coordinates.
Uint8List cameraFrameToJpeg(CameraFramePacket p) {
  if (p.width <= 0 ||
      p.height <= 0 ||
      ![0, 90, 180, 270].contains(p.rotation) ||
      p.planes.length != (p.bgra ? 1 : 3) ||
      p.rowStrides.length != p.planes.length ||
      p.pixelStrides.length != p.planes.length) {
    throw const FormatException('Unsupported camera packet');
  }
  for (var i = 0; i < p.planes.length; i++) {
    final w = i == 0 || p.bgra ? p.width : (p.width + 1) ~/ 2;
    final h = i == 0 || p.bgra ? p.height : (p.height + 1) ~/ 2;
    final pixelSize = p.bgra ? 4 : 1;
    if (p.pixelStrides[i] < pixelSize ||
        p.rowStrides[i] < (w - 1) * p.pixelStrides[i] + pixelSize ||
        p.planes[i].length <
            (h - 1) * p.rowStrides[i] +
                (w - 1) * p.pixelStrides[i] +
                pixelSize) {
      throw const FormatException('Invalid camera plane stride/length');
    }
  }
  final image = img.Image(width: p.width, height: p.height);
  int sample(int plane, int x, int y) =>
      p.planes[plane][y * p.rowStrides[plane] + x * p.pixelStrides[plane]];
  int clamp(double v) => v.round().clamp(0, 255);
  for (var y = 0; y < p.height; y++) {
    for (var x = 0; x < p.width; x++) {
      if (p.bgra) {
        final at = y * p.rowStrides[0] + x * p.pixelStrides[0];
        image.setPixelRgb(
          x,
          y,
          p.planes[0][at + 2],
          p.planes[0][at + 1],
          p.planes[0][at],
        );
      } else {
        // Android YUV_420_888: BT.601 limited-range conversion. Actual camera
        // colour calibration remains a device validation item.
        final yy = (sample(0, x, y) - 16) * 1.164;
        final u = sample(1, x ~/ 2, y ~/ 2) - 128;
        final v = sample(2, x ~/ 2, y ~/ 2) - 128;
        image.setPixelRgb(
          x,
          y,
          clamp(yy + 1.596 * v),
          clamp(yy - .392 * u - .813 * v),
          clamp(yy + 2.017 * u),
        );
      }
    }
  }
  final upright = p.rotation == 0
      ? image
      : img.copyRotate(image, angle: p.rotation);
  return img.encodeJpg(upright, quality: 90);
}
