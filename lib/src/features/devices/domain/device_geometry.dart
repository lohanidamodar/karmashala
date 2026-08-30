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

/// How long `input swipe` is asked to hold still for a long press.
///
/// Android's own long-press threshold is 500 ms
/// (`ViewConfiguration.getLongPressTimeout()`); 700 ms clears it comfortably
/// without making the gesture feel stuck, and leaves room for the ~223 ms the
/// adb round trip costs before the press even begins.
const Duration kLongPressHoldDuration = Duration(milliseconds: 700);

/// Bounds on the duration handed to `input swipe` for a drag.
///
/// Below the floor Android treats the gesture as a fling with an implausible
/// velocity; above the ceiling a single `input swipe` blocks for that long,
/// and the user has already let go.
const Duration kMinSwipeDuration = Duration(milliseconds: 60);
const Duration kMaxSwipeDuration = Duration(milliseconds: 1500);

/// The duration to pass to `input swipe` for a drag the user held for
/// [held].
///
/// This is what separates a flick from a slow drag: `input swipe` interpolates
/// between two points over the duration given, so the duration *is* the
/// velocity. Passing a fixed value would make every gesture scroll by the same
/// amount regardless of how the user moved.
Duration swipeDurationFor(Duration held) {
  if (held < kMinSwipeDuration) return kMinSwipeDuration;
  if (held > kMaxSwipeDuration) return kMaxSwipeDuration;
  return held;
}
