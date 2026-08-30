import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/device_gesture_sink.dart';
import '../domain/device_geometry.dart';

/// The touch target laid over the live view.
///
/// It is a raw [Listener], not a `GestureDetector`, and that is the whole point
/// of Loop 36. A gesture recogniser deliberately *withholds* events: nothing is
/// reported until the ~18 px touch slop is beaten, and a pan arrives as a
/// summary. The device is the thing that should be deciding what a gesture
/// means — it has Android's own slop, timeout and velocity tracker — so every
/// pointer event is forwarded as it happens and no interpretation is done here.
///
/// Positions are reported as `0..1` fractions of the picture rather than device
/// pixels, because the two transports want different coordinate spaces for the
/// same touch. See [widgetPointToFraction].
///
/// Separated from the pane for one reason: the pane's live view needs a real
/// video controller to build, so gestures cannot be widget-tested there. This
/// widget takes any [child], so a test can mount it over a plain box.
class DeviceTouchSurface extends StatefulWidget {
  const DeviceTouchSurface({
    super.key,
    required this.child,
    this.sink,
    this.pinchWithModifier = true,
  });

  /// Where pointer events go. `null` disables input.
  final DeviceGestureSink? sink;

  /// Whether holding Ctrl turns a drag into a two-finger pinch about the centre
  /// of the picture, the way scrcpy's own client does it.
  ///
  /// A mouse can only ever be one finger, so without this there is no way to
  /// pinch from a desktop at all. It is ignored by a sink that cannot express a
  /// second pointer.
  final bool pinchWithModifier;

  final Widget child;

  @override
  State<DeviceTouchSurface> createState() => _DeviceTouchSurfaceState();
}

/// One finger currently down, and the bookkeeping needed to report it.
class _ActivePointer {
  _ActivePointer({
    required this.id,
    required this.startedAt,
    required this.mirrorId,
  });

  /// The small, dense id sent on the wire. Flutter's own pointer numbers grow
  /// without bound across the life of the app; scrcpy keys a fixed-size
  /// `PointersState` on what we send, so it gets the tidy version.
  final int id;

  final Duration startedAt;

  /// The pinch partner's wire id, when this drag is a Ctrl-pinch.
  final int? mirrorId;
}

class _DeviceTouchSurfaceState extends State<DeviceTouchSurface> {
  final Map<int, _ActivePointer> _active = <int, _ActivePointer>{};

  /// Smallest wire id not in use. scrcpy allows ten simultaneous pointers and
  /// refuses the eleventh with "Too many pointers for touch event", so ids are
  /// recycled as fingers lift rather than counted upwards.
  int _allocateId() {
    final taken = <int>{
      for (final pointer in _active.values) ...[
        pointer.id,
        if (pointer.mirrorId != null) pointer.mirrorId!,
      ],
    };
    for (var id = 0; id < 10; id++) {
      if (!taken.contains(id)) return id;
    }
    return -1;
  }

  ({double x, double y}) _fraction(Offset local, Size box) =>
      widgetPointToFraction(local: local, box: box);

  @override
  void dispose() {
    final sink = widget.sink;
    if (sink != null) {
      for (final pointer in _active.values) {
        sink.pointerCancel(pointer.id);
        if (pointer.mirrorId != null) sink.pointerCancel(pointer.mirrorId!);
      }
    }
    _active.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sink = widget.sink;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: sink == null
              ? null
              : (event) {
                  if (_active.containsKey(event.pointer)) return;
                  final id = _allocateId();
                  if (id < 0) return;
                  final pinch =
                      widget.pinchWithModifier &&
                      HardwareKeyboard.instance.isControlPressed &&
                      _active.isEmpty;
                  final mirrorId = pinch ? _allocateIdBesides(id) : null;
                  _active[event.pointer] = _ActivePointer(
                    id: id,
                    startedAt: event.timeStamp,
                    mirrorId: mirrorId,
                  );
                  final point = _fraction(event.localPosition, box);
                  sink.pointerDown(id, point.x, point.y);
                  if (mirrorId != null) {
                    sink.pointerDown(mirrorId, 1 - point.x, 1 - point.y);
                  }
                },
          onPointerMove: sink == null
              ? null
              : (event) {
                  final pointer = _active[event.pointer];
                  if (pointer == null) return;
                  final point = _fraction(event.localPosition, box);
                  sink.pointerMove(pointer.id, point.x, point.y);
                  if (pointer.mirrorId != null) {
                    sink.pointerMove(
                      pointer.mirrorId!,
                      1 - point.x,
                      1 - point.y,
                    );
                  }
                },
          onPointerUp: sink == null
              ? null
              : (event) {
                  final pointer = _active.remove(event.pointer);
                  if (pointer == null) return;
                  final point = _fraction(event.localPosition, box);
                  final held = event.timeStamp - pointer.startedAt;
                  if (pointer.mirrorId != null) {
                    sink.pointerUp(
                      pointer.mirrorId!,
                      1 - point.x,
                      1 - point.y,
                      held,
                    );
                  }
                  sink.pointerUp(pointer.id, point.x, point.y, held);
                },
          onPointerCancel: sink == null
              ? null
              : (event) {
                  final pointer = _active.remove(event.pointer);
                  if (pointer == null) return;
                  if (pointer.mirrorId != null) {
                    sink.pointerCancel(pointer.mirrorId!);
                  }
                  sink.pointerCancel(pointer.id);
                },
          child: widget.child,
        );
      },
    );
  }

  int? _allocateIdBesides(int used) {
    for (var id = 0; id < 10; id++) {
      if (id == used) continue;
      final taken = _active.values.any(
        (pointer) => pointer.id == id || pointer.mirrorId == id,
      );
      if (!taken) return id;
    }
    return null;
  }
}

/// Shown in the pane, because a pinch is not discoverable otherwise.
const String kPinchHint = 'Hold Ctrl and drag to pinch';
