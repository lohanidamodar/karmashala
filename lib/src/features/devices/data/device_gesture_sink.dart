// Where a gesture made in the live view is sent.
//
// The live view always speaks the same continuous language — pointer down,
// pointer moved, pointer up, in `0..1` fractions of the picture — and the sink
// decides what that means on the wire. There are two:
//
// * [ScrcpyGestureSink] forwards each event as it happens, so the device sees
//   the same motion the user made. This is the one that makes a slow drag track
//   the finger and a flick fling.
// * [AdbGestureSink] cannot: `adb shell input` has no concept of a partial
//   gesture. It therefore *accumulates* the pointer events and replays them as
//   one `tap`, `swipe` or held `swipe` on release — exactly the Loop 34
//   behaviour, moved here so nothing regresses when the control socket is
//   unavailable.
//
// One live view, one wiring, and the fallback is a swap of this object.

import 'dart:math' as math;

import '../domain/device_geometry.dart';
import '../domain/device_input.dart';
import 'adb_service.dart';
import 'scrcpy_control.dart';

/// How the live view is driving the device right now. Surfaced in the UI: the
/// two transports feel completely different, so which one is active is not an
/// implementation detail.
enum DeviceGestureTransport {
  /// scrcpy's control socket — real down/move/up events, ~5–10 ms each.
  scrcpyControl('Control socket', true),

  /// `adb shell input` — one synthesised gesture on release, ~223 ms.
  adbInput('adb input', false);

  const DeviceGestureTransport(this.label, this.isContinuous);

  final String label;

  /// Whether the device sees motion *during* the gesture rather than only at
  /// the end of it.
  final bool isContinuous;
}

/// Receives pointer events from the live view in picture fractions (`0..1`).
abstract interface class DeviceGestureSink {
  DeviceGestureTransport get transport;

  void pointerDown(int pointer, double fx, double fy);

  void pointerMove(int pointer, double fx, double fy);

  void pointerUp(int pointer, double fx, double fy, Duration held);

  void pointerCancel(int pointer);
}

/// Sends every pointer event straight down scrcpy's control socket.
class ScrcpyGestureSink implements DeviceGestureSink {
  ScrcpyGestureSink({
    required this.connection,
    required this.videoSize,
    this.onDropped,
  });

  final ScrcpyControlConnection connection;

  /// scrcpy's current video size, read afresh for every event: it changes when
  /// the device rotates, and a stale value means every subsequent touch is
  /// silently discarded by `PositionMapper.map`.
  final DeviceScreenSize? Function() videoSize;

  /// Called when the socket has gone away, so the caller can fall back.
  final void Function()? onDropped;

  /// Pointers that were successfully put down, so a move or an up for a pointer
  /// whose down never made it is not sent on its own.
  final Set<int> _down = <int>{};

  @override
  DeviceGestureTransport get transport => DeviceGestureTransport.scrcpyControl;

  bool _send(int pointer, int action, double fx, double fy, double pressure) {
    final size = videoSize();
    if (size == null) return false;
    final point = fractionToDevice(fx: fx, fy: fy, screen: size);
    final ok = connection.send(
      ScrcpyTouchEvent(
        action: action,
        pointerId: pointer,
        x: point.x,
        y: point.y,
        videoWidth: size.width,
        videoHeight: size.height,
        pressure: pressure,
      ).encode(),
    );
    if (!ok) onDropped?.call();
    return ok;
  }

  @override
  void pointerDown(int pointer, double fx, double fy) {
    if (_send(pointer, AndroidMotionAction.down, fx, fy, 1.0)) {
      _down.add(pointer);
    }
  }

  @override
  void pointerMove(int pointer, double fx, double fy) {
    if (!_down.contains(pointer)) return;
    _send(pointer, AndroidMotionAction.move, fx, fy, 1.0);
  }

  @override
  void pointerUp(int pointer, double fx, double fy, Duration held) {
    if (!_down.remove(pointer)) return;
    // Pressure zero on release: that is what a real touchscreen reports, and
    // what Android's velocity tracker expects to close a fling.
    _send(pointer, AndroidMotionAction.up, fx, fy, 0.0);
  }

  @override
  void pointerCancel(int pointer) {
    if (!_down.remove(pointer)) return;
    _send(pointer, AndroidMotionAction.cancel, 0, 0, 0.0);
  }
}

/// Replays a gesture through `adb shell input` once it is over.
///
/// This is the fallback, and it is honest about what it can do: the device sees
/// nothing until the finger lifts, and then sees one synthesised gesture. Only
/// the first pointer is followed — `input` has no multi-touch.
class AdbGestureSink implements DeviceGestureSink {
  AdbGestureSink({
    required this.adb,
    required this.serial,
    required this.screen,
    this.onError,
  });

  final AdbService adb;
  final String serial;
  final DeviceScreenSize screen;
  final void Function(Object error)? onError;

  /// Touch slop, in fractions of the *shorter* screen edge. Android's own slop
  /// is ~18 dp; anything under this is a tap or a long press, not a drag.
  static const double _slopFraction = 0.015;

  int? _pointer;
  ({double x, double y})? _start;

  @override
  DeviceGestureTransport get transport => DeviceGestureTransport.adbInput;

  @override
  void pointerDown(int pointer, double fx, double fy) {
    if (_pointer != null) return; // Secondary fingers cannot be expressed.
    _pointer = pointer;
    _start = (x: fx, y: fy);
  }

  @override
  void pointerMove(int pointer, double fx, double fy) {
    // Nothing to do: `adb shell input` has no way to express a gesture that is
    // still happening. The whole drag is replayed on release instead.
  }

  @override
  void pointerUp(int pointer, double fx, double fy, Duration held) {
    if (_pointer != pointer) return;
    final start = _start;
    _pointer = null;
    _start = null;
    if (start == null) return;

    final from = fractionToDevice(fx: start.x, fy: start.y, screen: screen);
    final to = fractionToDevice(fx: fx, fy: fy, screen: screen);
    final moved = math.sqrt(
      math.pow(fx - start.x, 2) + math.pow(fy - start.y, 2),
    );

    Future<void> action;
    if (moved <= _slopFraction && held < kLongPressHoldDuration) {
      action = adb.tap(serial, from.x, from.y);
    } else if (moved <= _slopFraction) {
      // A press that stayed still: a swipe that goes nowhere, held long enough
      // to beat Android's 500 ms long-press timeout.
      action = adb.swipe(
        serial,
        fromX: from.x,
        fromY: from.y,
        toX: from.x,
        toY: from.y,
        duration: kLongPressHoldDuration,
      );
    } else {
      // The duration *is* the velocity: `input swipe` interpolates over
      // whatever it is given, so a flick and a slow drag must not share one.
      action = adb.swipe(
        serial,
        fromX: from.x,
        fromY: from.y,
        toX: to.x,
        toY: to.y,
        duration: swipeDurationFor(held),
      );
    }
    action.catchError((Object error) => onError?.call(error));
  }

  @override
  void pointerCancel(int pointer) {
    if (_pointer != pointer) return;
    _pointer = null;
    _start = null;
  }
}
