import 'dart:typed_data';

/// The pixel size a picture's header declares, read without decoding it: a
/// PNG, GIF, BMP, WebP or JPEG. Null for anything else, or a header cut short.
({int width, int height})? imageDimensions(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final length = bytes.length;
  bool says(int at, String text) {
    if (at + text.length > length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[at + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (length >= 24 && bytes[0] == 0x89 && says(1, 'PNG')) {
    return (width: data.getUint32(16), height: data.getUint32(20));
  }
  if (length >= 10 && says(0, 'GIF8')) {
    return (
      width: data.getUint16(6, Endian.little),
      height: data.getUint16(8, Endian.little),
    );
  }
  if (length >= 26 && says(0, 'BM')) {
    // A bottom-up bitmap stores its height negative.
    return (
      width: data.getInt32(18, Endian.little).abs(),
      height: data.getInt32(22, Endian.little).abs(),
    );
  }
  if (length >= 30 && says(0, 'RIFF') && says(8, 'WEBP')) {
    if (says(12, 'VP8 ')) {
      return (
        width: data.getUint16(26, Endian.little) & 0x3fff,
        height: data.getUint16(28, Endian.little) & 0x3fff,
      );
    }
    if (says(12, 'VP8L')) {
      final bits = data.getUint32(21, Endian.little);
      return (width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1);
    }
    if (says(12, 'VP8X')) {
      int three(int at) =>
          bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16);
      return (width: three(24) + 1, height: three(27) + 1);
    }
    return null;
  }
  if (length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var at = 2;
    while (at + 9 < length) {
      if (bytes[at] != 0xff) {
        at++;
        continue;
      }
      final marker = bytes[at + 1];
      if (marker == 0xff) {
        at++;
        continue;
      }
      // Markers that carry no length.
      if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
        at += 2;
        continue;
      }
      // A start-of-frame: every 0xC_ but the Huffman, arithmetic and
      // reserved tables.
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc) {
        return (height: data.getUint16(at + 5), width: data.getUint16(at + 7));
      }
      at += 2 + data.getUint16(at + 2);
    }
  }
  return null;
}
