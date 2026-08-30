import 'package:flutter/widgets.dart';

import '../domain/device_geometry.dart';
import '../domain/device_input.dart';

/// A device-coordinate touch target laid over the live view.
///
/// Separated from the pane for one reason: the pane's live view needs a real
/// video controller to build, so gestures cannot be widget-tested there. This
/// widget takes any [child], so a test can mount it over a plain box and drive
/// real taps, long presses and drags through it.
///
/// Every callback reports **device pixels**, converted with the same
/// [widgetPointToDevice] the pane has always used — Loop 27 verified that
/// mapping end to end at zero pixel error, and a second copy of it would be a
/// second chance to get it wrong.
class DeviceTouchSurface extends StatefulWidget {
  const DeviceTouchSurface({
    super.key,
    required this.screen,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSwipe,
  });

  /// The device's coordinate space. `null` disables input: without it there is
  /// nothing to convert widget coordinates into.
  final DeviceScreenSize? screen;

  final Widget child;

  final void Function(int x, int y)? onTap;

  /// A press held in one place. The device is asked to hold for
  /// [kLongPressHoldDuration].
  final void Function(int x, int y)? onLongPress;

  /// A drag, reported once on release with the duration the user actually
  /// spent on it — that duration is the gesture's velocity, so a flick and a
  /// slow drag do different things.
  final void Function(
    int fromX,
    int fromY,
    int toX,
    int toY,
    Duration duration,
  )?
  onSwipe;

  @override
  State<DeviceTouchSurface> createState() => _DeviceTouchSurfaceState();
}

class _DeviceTouchSurfaceState extends State<DeviceTouchSurface> {
  Offset? _panStart;
  Offset? _panLast;

  /// Pointer-event timestamps, which are what actually say how long the user
  /// spent on the gesture. A wall clock would also be measuring frame
  /// scheduling, and would read zero under a test's fake clock.
  Duration? _panStartStamp;
  Duration? _panLastStamp;

  /// Fallback for platforms that do not stamp their pointer events.
  final Stopwatch _panClock = Stopwatch();

  Duration get _held {
    final start = _panStartStamp;
    final last = _panLastStamp;
    if (start != null && last != null && last > start) return last - start;
    return _panClock.elapsed;
  }

  void _reset() {
    _panClock.stop();
    _panStart = null;
    _panLast = null;
    _panStartStamp = null;
    _panLastStamp = null;
  }

  @override
  Widget build(BuildContext context) {
    final screen = widget.screen;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        ({int x, int y}) toDevice(Offset local) =>
            widgetPointToDevice(local: local, box: box, screen: screen!);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: screen == null || widget.onTap == null
              ? null
              : (details) {
                  final point = toDevice(details.localPosition);
                  widget.onTap!(point.x, point.y);
                },
          // onLongPressStart rather than onLongPress: only the former carries
          // the position, and a long press with no position is useless here.
          onLongPressStart: screen == null || widget.onLongPress == null
              ? null
              : (details) {
                  final point = toDevice(details.localPosition);
                  widget.onLongPress!(point.x, point.y);
                },
          // The finger goes down here; onPanStart only fires once the drag has
          // beaten the ~18 px touch slop, by which point the reported position
          // is already well into the gesture. Starting the swipe there loses
          // that much travel from every drag.
          onPanDown: screen == null || widget.onSwipe == null
              ? null
              : (details) {
                  _panStart = details.localPosition;
                  _panLast = details.localPosition;
                },
          onPanStart: screen == null || widget.onSwipe == null
              ? null
              : (details) {
                  _panStart ??= details.localPosition;
                  _panLast = details.localPosition;
                  _panStartStamp = details.sourceTimeStamp;
                  _panLastStamp = details.sourceTimeStamp;
                  _panClock
                    ..reset()
                    ..start();
                },
          onPanUpdate: screen == null || widget.onSwipe == null
              ? null
              : (details) {
                  _panLast = details.localPosition;
                  _panLastStamp = details.sourceTimeStamp ?? _panLastStamp;
                },
          onPanEnd: screen == null || widget.onSwipe == null
              ? null
              : (_) {
                  _panClock.stop();
                  final held = _held;
                  final start = _panStart;
                  final end = _panLast;
                  _reset();
                  if (start == null || end == null) return;
                  final from = toDevice(start);
                  final to = toDevice(end);
                  widget.onSwipe!(
                    from.x,
                    from.y,
                    to.x,
                    to.y,
                    swipeDurationFor(held),
                  );
                },
          onPanCancel: _reset,
          child: widget.child,
        );
      },
    );
  }
}
