import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// How two captures are shown together.
enum ScreenshotCompareMode {
  /// Changed pixels in red over a faded copy of the after image.
  diff,
  sideBySide,

  /// The two blended half and half.
  overlay;

  static ScreenshotCompareMode? parse(String? value) => switch (value) {
    null || 'diff' => ScreenshotCompareMode.diff,
    'side_by_side' || 'sideBySide' => ScreenshotCompareMode.sideBySide,
    'overlay' => ScreenshotCompareMode.overlay,
    _ => null,
  };
}

/// What differs between two PNGs, measured over the larger of their two
/// canvases: a pixel only one image covers counts as changed.
class ScreenshotComparison {
  const ScreenshotComparison({
    required this.beforeWidth,
    required this.beforeHeight,
    required this.afterWidth,
    required this.afterHeight,
    required this.changedPixels,
    required this.totalPixels,
    this.changedBox,
    this.png,
  });

  final int beforeWidth;
  final int beforeHeight;
  final int afterWidth;
  final int afterHeight;
  final int changedPixels;
  final int totalPixels;

  /// The smallest rectangle holding every changed pixel, or null for none.
  final ({int x, int y, int width, int height})? changedBox;

  /// The comparison drawn in the mode asked for, when one was.
  final Uint8List? png;

  double get changedPercent =>
      totalPixels == 0 ? 0 : changedPixels * 100 / totalPixels;

  bool get sameSize => beforeWidth == afterWidth && beforeHeight == afterHeight;

  Map<String, Object?> toJson() => {
    'changedPercent': double.parse(changedPercent.toStringAsFixed(3)),
    'changedPixels': changedPixels,
    'totalPixels': totalPixels,
    'before': {'width': beforeWidth, 'height': beforeHeight},
    'after': {'width': afterWidth, 'height': afterHeight},
    if (changedBox case final box?)
      'changedBox': {
        'x': box.x,
        'y': box.y,
        'width': box.width,
        'height': box.height,
      },
  };
}

/// Compares [before] and [after] pixel by pixel. A pixel is changed when any
/// channel differs by more than [tolerance] (0–255), which absorbs
/// anti-aliasing noise. Throws [FormatException] for bytes that are not a PNG.
ScreenshotComparison compareScreenshots(
  Uint8List before,
  Uint8List after, {
  int tolerance = 8,
  ScreenshotCompareMode? draw,
}) {
  final a = _rgba(before, 'before');
  final b = _rgba(after, 'after');
  final width = math.max(a.width, b.width);
  final height = math.max(a.height, b.height);
  final changed = Uint8List(width * height);
  var count = 0;
  var minX = width, minY = height, maxX = -1, maxY = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final inA = x < a.width && y < a.height;
      final inB = x < b.width && y < b.height;
      var differs = inA != inB;
      if (inA && inB) {
        final i = (y * a.width + x) * 4;
        final j = (y * b.width + x) * 4;
        for (var c = 0; c < 4 && !differs; c++) {
          differs = (a.bytes[i + c] - b.bytes[j + c]).abs() > tolerance;
        }
      }
      if (!differs) continue;
      changed[y * width + x] = 1;
      count++;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  return ScreenshotComparison(
    beforeWidth: a.width,
    beforeHeight: a.height,
    afterWidth: b.width,
    afterHeight: b.height,
    changedPixels: count,
    totalPixels: width * height,
    changedBox: count == 0
        ? null
        : (x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
    png: switch (draw) {
      null => null,
      ScreenshotCompareMode.diff => _diff(b, changed, width, height),
      ScreenshotCompareMode.sideBySide => _sideBySide(a, b),
      ScreenshotCompareMode.overlay => _overlay(a, b, width, height),
    },
  );
}

typedef _Rgba = ({int width, int height, Uint8List bytes});

_Rgba _rgba(Uint8List png, String which) {
  final decoded = img.decodePng(png);
  if (decoded == null) {
    throw FormatException('The $which capture is not a PNG Karmashala can read.');
  }
  final rgba = decoded.convert(
    format: img.Format.uint8,
    numChannels: 4,
    alpha: 255,
  );
  return (
    width: rgba.width,
    height: rgba.height,
    bytes: rgba.getBytes(order: img.ChannelOrder.rgba),
  );
}

Uint8List _encode(int width, int height, Uint8List rgba) => img.encodePng(
  img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  ),
);

Uint8List _diff(_Rgba after, Uint8List changed, int width, int height) {
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      if (changed[y * width + x] == 1) {
        out
          ..[o] = 230
          ..[o + 1] = 30
          ..[o + 2] = 30
          ..[o + 3] = 255;
        continue;
      }
      // Unchanged: the after image in grey at a quarter strength over white.
      var grey = 255;
      if (x < after.width && y < after.height) {
        final i = (y * after.width + x) * 4;
        final luma =
            (after.bytes[i] * 299 +
                after.bytes[i + 1] * 587 +
                after.bytes[i + 2] * 114) ~/
            1000;
        grey = 255 - (255 - luma) ~/ 4;
      }
      out
        ..[o] = grey
        ..[o + 1] = grey
        ..[o + 2] = grey
        ..[o + 3] = 255;
    }
  }
  return _encode(width, height, out);
}

Uint8List _sideBySide(_Rgba before, _Rgba after) {
  const gap = 16;
  final width = before.width + gap + after.width;
  final height = math.max(before.height, after.height);
  final out = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 255);
  void place(_Rgba image, int left) {
    for (var y = 0; y < image.height; y++) {
      final from = y * image.width * 4;
      out.setRange(
        (y * width + left) * 4,
        (y * width + left + image.width) * 4,
        image.bytes,
        from,
      );
    }
  }

  place(before, 0);
  place(after, before.width + gap);
  return _encode(width, height, out);
}

Uint8List _overlay(_Rgba before, _Rgba after, int width, int height) {
  final out = Uint8List(width * height * 4);
  int channel(_Rgba image, int x, int y, int c) =>
      x < image.width && y < image.height
      ? image.bytes[(y * image.width + x) * 4 + c]
      : 255;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      for (var c = 0; c < 3; c++) {
        out[o + c] = (channel(before, x, y, c) + channel(after, x, y, c)) ~/ 2;
      }
      out[o + 3] = 255;
    }
  }
  return _encode(width, height, out);
}

/// A PNG's size from its header, without decoding it; null for anything else.
({int width, int height})? pngSize(Uint8List png) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (png.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (png[i] != signature[i]) return null;
  }
  final header = ByteData.sublistView(png, 16, 24);
  return (width: header.getUint32(0), height: header.getUint32(4));
}
