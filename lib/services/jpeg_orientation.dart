import 'dart:typed_data';
import 'dart:ui' as ui;

int jpegExifOrientation(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return 1;
  var offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset++] != 0xff) return 1;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) return 1;
    final marker = bytes[offset++];
    if (marker == 0xda || marker == 0xd9) return 1;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) return 1;
    final length = (bytes[offset] << 8) | bytes[offset + 1];
    final end = offset + length;
    if (length < 2 || end > bytes.length) return 1;
    final start = offset + 2;
    if (marker == 0xe1 &&
        end - start >= 14 &&
        bytes[start] == 0x45 &&
        bytes[start + 1] == 0x78 &&
        bytes[start + 2] == 0x69 &&
        bytes[start + 3] == 0x66 &&
        bytes[start + 4] == 0 &&
        bytes[start + 5] == 0) {
      final tiff = start + 6;
      final little = bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49;
      final big = bytes[tiff] == 0x4d && bytes[tiff + 1] == 0x4d;
      if (!little && !big) return 1;
      final data = ByteData.sublistView(bytes, tiff, end);
      final order = little ? Endian.little : Endian.big;
      if (data.getUint16(2, order) != 42) return 1;
      final ifd = data.getUint32(4, order);
      if (ifd < 8 || ifd + 2 > data.lengthInBytes) return 1;
      final count = data.getUint16(ifd, order);
      if (ifd + 2 + count * 12 > data.lengthInBytes) return 1;
      for (var i = 0; i < count; i++) {
        final entry = ifd + 2 + i * 12;
        if (data.getUint16(entry, order) != 0x0112) continue;
        if (data.getUint16(entry + 2, order) != 3 ||
            data.getUint32(entry + 4, order) != 1) {
          return 1;
        }
        final orientation = data.getUint16(entry + 8, order);
        return orientation >= 1 && orientation <= 8 ? orientation : 1;
      }
    }
    offset = end;
  }
  return 1;
}

Future<Uint8List> uprightImageBytes(Uint8List bytes) async {
  if (jpegExifOrientation(bytes) == 1) return bytes;
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png == null
        ? bytes
        : png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } catch (_) {
    return bytes;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
