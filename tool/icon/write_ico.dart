/// Packs the rendered tray PNGs into the multi-size .ico files Windows wants.
///
///   flutter test tool/icon/render_icons.dart
///   dart run tool/icon/write_ico.dart
library;

import 'dart:io';

import 'package:image/image.dart';

/// What a Windows tray actually asks for, smallest first.
const _sizes = [16, 20, 24, 32, 48, 64, 256];

void main() {
  _pack('assets/icon/tray_source.png', 'assets/tray_icon.ico');
  _pack('assets/icon/tray_source_attention.png', 'assets/tray_icon_attention.ico');
  stdout.writeln('Wrote both tray icons.');
}

void _pack(String source, String target) {
  final image = decodePng(File(source).readAsBytesSync());
  if (image == null) {
    stderr.writeln('$source is not a readable PNG.');
    exitCode = 1;
    return;
  }
  final frames = [
    for (final size in _sizes)
      copyResize(
        image,
        width: size,
        height: size,
        interpolation: Interpolation.average,
      ),
  ];
  File(target).writeAsBytesSync(IcoEncoder().encodeImages(frames));
}
