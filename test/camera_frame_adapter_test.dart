import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_navigation/services/camera_frame_adapter.dart';

void main() {
  CameraFramePacket packet(int rotation) => CameraFramePacket(
    width: 2,
    height: 4,
    rotation: rotation,
    planes: [
      Uint8List.fromList([
        30,
        30,
        0,
        0,
        30,
        30,
        0,
        0,
        220,
        220,
        0,
        0,
        220,
        220,
      ]),
      Uint8List.fromList([128, 0, 0, 128]),
      Uint8List.fromList([128, 0, 0, 128]),
    ],
    rowStrides: [4, 3, 3],
    pixelStrides: [1, 2, 2],
  );

  test('padded rows, chroma pixel stride, JPEG and clockwise rotation', () {
    final upright = img.decodeJpg(cameraFrameToJpeg(packet(90)))!;
    expect((upright.width, upright.height), (4, 2));
    // Bottom of sensor frame becomes left after clockwise 90° rotation.
    expect(upright.getPixel(0, 0).r, greaterThan(180));
    expect(upright.getPixel(3, 0).r, lessThan(60));
    for (final angle in [0, 90, 180, 270]) {
      final decoded = img.decodeJpg(cameraFrameToJpeg(packet(angle)))!;
      expect(decoded.width, angle % 180 == 0 ? 2 : 4);
    }
  });

  test('BGRA channel ordering and malformed plane rejection', () {
    final decoded = img.decodeJpg(
      cameraFrameToJpeg(
        CameraFramePacket(
          width: 1,
          height: 1,
          rotation: 0,
          bgra: true,
          planes: [
            Uint8List.fromList([0, 0, 255, 255]),
          ],
          rowStrides: [4],
          pixelStrides: [4],
        ),
      ),
    )!;
    expect(decoded.getPixel(0, 0).r, greaterThan(240));
    expect(decoded.getPixel(0, 0).b, lessThan(15));
    expect(
      () => cameraFrameToJpeg(
        CameraFramePacket(
          width: 2,
          height: 2,
          rotation: 0,
          planes: [Uint8List(1)],
          rowStrides: [1],
          pixelStrides: [1],
        ),
      ),
      throwsFormatException,
    );
  });

  test('worker isolate produces a decodable JPEG', () async {
    final decoded = img.decodeJpg(await encodeCameraFrame(packet(270)))!;
    expect((decoded.width, decoded.height), (4, 2));
  });
}
