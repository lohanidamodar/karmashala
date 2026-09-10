import 'device_input.dart';

/// A point inside the live-view widget, in logical pixels. `dart:ui`'s `Offset`
/// as a plain record, so this package still runs under plain `dart test`; the
/// field names are `Offset`'s, so a caller passes `(dx: …, dy: …)`.
typedef WidgetPoint = ({double dx, double dy});

/// The size of the box the picture fills, in logical pixels — `dart:ui`'s
/// `Size` as a plain record, for the same reason as [WidgetPoint].
typedef WidgetBox = ({double width, double height});

/// Maps a point in the live-view widget to a device coordinate. The pane renders
/// the video inside an `AspectRatio` box matching the device, so the player never
/// letterboxes internally and the mapping is a pure scale.
({int x, int y}) widgetPointToDevice({
  required WidgetPoint local,
  required WidgetBox box,
  required DeviceScreenSize screen,
}) {
  final fraction = widgetPointToFraction(local: local, box: box);
  return fractionToDevice(fx: fraction.x, fy: fraction.y, screen: screen);
}

/// The same mapping stopped one step early, at a resolution-free `0..1` fraction
/// of the picture. The two transports want different spaces for the *same* touch
/// — `adb input` device pixels, scrcpy's socket **video** pixels, which it drops
/// silently when they differ — so the conversion happens late, in the sink.
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

/// How long `input swipe` is asked to hold still for a long press. Android's own
/// threshold is 500 ms; 700 ms clears it without making the gesture feel stuck.
const Duration kLongPressHoldDuration = Duration(milliseconds: 700);

/// Bounds on the duration handed to `input swipe` for a drag. Below the floor
/// Android reads a fling with an implausible velocity; above the ceiling the
/// call blocks for that long, after the user has let go.
const Duration kMinSwipeDuration = Duration(milliseconds: 60);
const Duration kMaxSwipeDuration = Duration(milliseconds: 1500);

/// The duration to pass to `input swipe` for a drag the user held for [held].
/// `input swipe` interpolates over whatever duration it is given, so the
/// duration *is* the velocity; a fixed one scrolls the same however they moved.
Duration swipeDurationFor(Duration held) {
  if (held < kMinSwipeDuration) return kMinSwipeDuration;
  if (held > kMaxSwipeDuration) return kMaxSwipeDuration;
  return held;
}
