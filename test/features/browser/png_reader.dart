import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A decoded 8-bit PNG: dimensions plus straight RGBA samples.
class DecodedPng {
  DecodedPng({required this.width, required this.height, required this.rgba});

  final int width;
  final int height;
  final Uint8List rgba;

  /// The colour at a pixel, as `#rrggbb`.
  String hexAt(int x, int y) {
    final offset = (y * width + x) * 4;
    return '#'
        '${rgba[offset].toRadixString(16).padLeft(2, '0')}'
        '${rgba[offset + 1].toRadixString(16).padLeft(2, '0')}'
        '${rgba[offset + 2].toRadixString(16).padLeft(2, '0')}';
  }

  /// The most common colour in the image, with the fraction of pixels it
  /// covers. Used to prove a cropped screenshot really shows the element it
  /// claims to.
  MapEntry<String, double> dominantColour() {
    final counts = <String, int>{};
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final hex = hexAt(x, y);
        counts[hex] = (counts[hex] ?? 0) + 1;
      }
    }
    final total = width * height;
    final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return MapEntry(best.key, best.value / total);
  }
}

/// Minimal PNG decoder: 8-bit, non-interlaced, RGB or RGBA.
///
/// Deliberately hand-rolled rather than adding an image package for a
/// verification harness: it reads exactly the subset Chrome's
/// `Page.captureScreenshot` emits, and nothing ships with it.
DecodedPng decodePng(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) throw const FormatException('not a PNG');
  }
  var offset = 8;
  var width = 0;
  var height = 0;
  var colourType = 6;
  final idat = BytesBuilder();
  final view = ByteData.sublistView(bytes);

  while (offset < bytes.length) {
    final length = view.getUint32(offset);
    final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
    final data = bytes.sublist(offset + 8, offset + 8 + length);
    switch (type) {
      case 'IHDR':
        final header = ByteData.sublistView(data);
        width = header.getUint32(0);
        height = header.getUint32(4);
        if (data[8] != 8) throw const FormatException('only 8-bit PNGs');
        colourType = data[9];
        if (data[12] != 0) throw const FormatException('interlaced PNG');
      case 'IDAT':
        idat.add(data);
      case 'IEND':
        offset = bytes.length;
        continue;
    }
    offset += 12 + length;
  }

  final channels = switch (colourType) {
    2 => 3,
    6 => 4,
    _ => throw FormatException('unsupported colour type $colourType'),
  };
  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.toBytes()));
  final stride = width * channels;
  final out = Uint8List(width * height * 4);
  final previous = Uint8List(stride);
  final current = Uint8List(stride);

  var source = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[source++];
    for (var i = 0; i < stride; i++) {
      final value = raw[source + i];
      final left = i >= channels ? current[i - channels] : 0;
      final up = previous[i];
      final upLeft = i >= channels ? previous[i - channels] : 0;
      current[i] = switch (filter) {
        0 => value,
        1 => (value + left) & 0xff,
        2 => (value + up) & 0xff,
        3 => (value + ((left + up) >> 1)) & 0xff,
        4 => (value + _paeth(left, up, upLeft)) & 0xff,
        _ => throw FormatException('unknown PNG filter $filter'),
      };
    }
    source += stride;
    for (var x = 0; x < width; x++) {
      final from = x * channels;
      final to = (y * width + x) * 4;
      out[to] = current[from];
      out[to + 1] = current[from + 1];
      out[to + 2] = current[from + 2];
      out[to + 3] = channels == 4 ? current[from + 3] : 255;
    }
    previous.setAll(0, current);
  }
  return DecodedPng(width: width, height: height, rgba: out);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}
