/// Packs the rendered tray sources into what each platform's tray wants.
///
///   flutter test tool/icon/render_icons.dart
///   dart run tool/icon/write_ico.dart
///
/// Windows takes a multi-size `.ico`. macOS and Linux take a plain `.png` and
/// refuse an `.ico` outright — `tray_manager` hands the path to `NSImage`
/// (macOS) or to the AppIndicator/StatusNotifier icon theme (Linux), and
/// neither decodes ICO. Shipping only the `.ico` is why the tray came up blank
/// off Windows.
library;

import 'dart:io';

import 'package:image/image.dart';

/// What a Windows tray actually asks for, smallest first.
const _icoSizes = [16, 20, 24, 32, 48, 64, 256];

/// One square PNG for the macOS menu bar and the Linux tray.
///
/// 44px is the macOS status item's 22pt at @2x, which is the densest display
/// it is drawn on; both platforms scale down from there, and scaling down from
/// a size that is already right beats scaling down from 1024.
const _pngSize = 44;

void main() {
  _packIco('assets/icon/tray_source.png', 'assets/tray_icon.ico');
  _packIco(
    'assets/icon/tray_source_attention.png',
    'assets/tray_icon_attention.ico',
  );
  _packPng('assets/icon/tray_source.png', 'assets/tray_icon.png');
  _packPng(
    'assets/icon/tray_source_attention.png',
    'assets/tray_icon_attention.png',
  );
  stdout.writeln('Wrote tray icons: .ico for Windows, .png for macOS/Linux.');
}

Image? _read(String source) {
  final image = decodePng(File(source).readAsBytesSync());
  if (image == null) {
    stderr.writeln('$source is not a readable PNG.');
    exitCode = 1;
  }
  return image;
}

void _packIco(String source, String target) {
  final image = _read(source);
  if (image == null) return;
  final frames = [
    for (final size in _icoSizes)
      copyResize(
        image,
        width: size,
        height: size,
        interpolation: Interpolation.average,
      ),
  ];
  File(target).writeAsBytesSync(IcoEncoder().encodeImages(frames));
}

void _packPng(String source, String target) {
  final image = _read(source);
  if (image == null) return;
  File(target).writeAsBytesSync(
    encodePng(
      copyResize(
        image,
        width: _pngSize,
        height: _pngSize,
        interpolation: Interpolation.average,
      ),
    ),
  );
}
