import 'device_input.dart';

/// A point inside the live-view widget, in logical pixels.
///
/// `dart:ui`'s `Offset` as a plain record: the mapping below is arithmetic on
/// two doubles, and taking the Flutter type for it would put the whole widget
/// layer behind a package that otherwise runs under plain `dart test`. The
/// field names are `Offset`'s, so a caller holding one passes
/// `(dx: offset.dx, dy: offset.dy)` and reads the same code.
typedef WidgetPoint = ({double dx, double dy});

/// The size of the box the picture fills, in logical pixels — `dart:ui`'s
/// `Size` as a plain record, for the same reason as [WidgetPoint].
typedef WidgetBox = ({double width, double height});

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
  required WidgetPoint local,
  required WidgetBox box,
  required DeviceScreenSize screen,
}) {
  final fraction = widgetPointToFraction(local: local, box: box);
  return fractionToDevice(fx: fraction.x, fy: fraction.y, screen: screen);
}

/// The same mapping stopped one step early, at a resolution-free `0..1`
/// fraction of the picture.
///
/// Gestures are carried in this form because the two transports want different
/// coordinate spaces for the *same* touch: `adb shell input` wants device
/// pixels, while scrcpy's control socket wants **video** pixels and rejects
/// anything else (`PositionMapper.map` compares the declared size against the
/// video size and silently drops the event when they differ). Converting once,
/// late, in whichever sink is active keeps a single mapping instead of two.
({double x, double y}) widgetPointToFraction({
  required WidgetPoint local,
  required WidgetBox box,
}) {
  if (box.width <= 0 || box.height <= 0) return (x: 0, y: 0);
  return (
    x: (local.dx / box.width).clamp(0.0, 1.0),
    y: (local.dy / box.height).clamp(0.0, 1.0),
  );
}

/// Turns a `0..1` fraction of the picture into a pixel in [screen].
({int x, int y}) fractionToDevice({
  required double fx,
  required double fy,
  required DeviceScreenSize screen,
}) {
  final x = (fx * screen.width).round();
  final y = (fy * screen.height).round();
  return (
    x: x.clamp(0, screen.width > 0 ? screen.width - 1 : 0),
    y: y.clamp(0, screen.height > 0 ? screen.height - 1 : 0),
  );
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
