import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:karmashala_devices/devices.dart';

/// The touch target laid over the live view. A raw [Listener], never a
/// `GestureDetector`: a recogniser withholds events until ~18 px of slop.
class DeviceTouchSurface extends StatefulWidget {
  const DeviceTouchSurface({
    super.key,
    required this.child,
    this.sink,
    this.pinchWithModifier = true,
  });

  /// Where pointer events go. `null` disables input.
  final DeviceGestureSink? sink;

  /// Whether Ctrl turns a drag into a two-finger pinch about the centre, as
  /// scrcpy's client does: a mouse is one finger, so otherwise there is none.
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

  /// The small, dense id sent on the wire: Flutter's pointer numbers grow
  /// without bound, and scrcpy keys a fixed-size `PointersState` on ours.
  final int id;

  final Duration startedAt;

  /// The pinch partner's wire id, when this drag is a Ctrl-pinch.
  final int? mirrorId;
}

class _DeviceTouchSurfaceState extends State<DeviceTouchSurface> {
  final Map<int, _ActivePointer> _active = <int, _ActivePointer>{};

  /// Smallest wire id not in use: scrcpy refuses an eleventh pointer with
  /// "Too many pointers for touch event", so ids recycle as fingers lift.
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

  // `WidgetPoint`/`WidgetBox` are `Offset`/`Size` as plain records, so the
  // mapping lives in the package and Flutter's types stop here.
  ({double x, double y}) _fraction(Offset local, Size box) =>
      widgetPointToFraction(
        local: (dx: local.dx, dy: local.dy),
        box: (width: box.width, height: box.height),
      );

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
