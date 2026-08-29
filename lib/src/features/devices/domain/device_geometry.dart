import 'dart:ui' show Offset, Size;

import 'device_input.dart';

/// Maps a point in the live-view widget to a device coordinate.
///
/// The pane renders the video inside an `AspectRatio` box matching the device's
/// aspect ratio, with the video filling that box. That is a deliberate design
/// choice: it means the player never letterboxes internally, so the widget's box
/// *is* the picture and the mapping is a pure scale — we never have to ask the
/// video library where it decided to put the image.
///
/// Verified against a running emulator: a Settings row centred at device
/// (954, 338) on a 1080x2400 screen appears at (357.8, 126.8) in a 405x900 pane
/// and maps back with zero pixel error.
({int x, int y}) widgetPointToDevice({
  required Offset local,
  required Size box,
  required DeviceScreenSize screen,
}) {
  if (box.width <= 0 || box.height <= 0) {
    return (x: 0, y: 0);
  }
  final x = (local.dx / box.width * screen.width).round();
  final y = (local.dy / box.height * screen.height).round();
  return (x: x.clamp(0, screen.width - 1), y: y.clamp(0, screen.height - 1));
}
