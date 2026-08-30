// scrcpy's control protocol: the client→server half, and the socket that
// carries it.
//
// Every constant and every field order below was read out of **the
// scrcpy-server jar this app actually deploys** (`assets/scrcpy/scrcpy-server`)
// by disassembling it, not from documentation. Loop 27 learned that lesson on
// the video framing, where the wire and the docs disagreed; here the jar is
// both. The methods that were read are
// `ControlMessageReader.read`/`parseInjectTouchEvent`/`parsePosition`,
// `Binary.u16FixedPointToFloat`, `Controller.injectTouch` and
// `PositionMapper.map`.
//
// The one non-obvious rule, and the one that makes touches silently vanish if
// broken: **the width/height in a touch message must equal scrcpy's *video*
// size**, not the device's screen size. `PositionMapper.map` compares the two
// and returns `null` — dropping the event without a word — when they differ.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/logging/app_logger.dart';

/// Control-message type ids.
///
/// Read from `ControlMessageReader.read`'s packed-switch: 23 arms, first key 0.
abstract final class ScrcpyControlType {
  static const int injectKeycode = 0;
  static const int injectText = 1;
  static const int injectTouchEvent = 2;
  static const int injectScrollEvent = 3;
  static const int backOrScreenOn = 4;
}

/// The `MotionEvent.ACTION_*` values a touch message may carry.
///
/// Only these four are ever sent: `Controller.injectTouch` turns `down`/`up`
/// into `ACTION_POINTER_DOWN`/`ACTION_POINTER_UP` itself, ORing in the pointer
/// index, once more than one pointer is down. That is why multi-touch needs
/// nothing here beyond distinct [ScrcpyTouchEvent.pointerId]s.
abstract final class AndroidMotionAction {
  static const int down = 0;
  static const int up = 1;
  static const int move = 2;
  static const int cancel = 3;
}

/// Pointer ids scrcpy treats specially, listed so we can stay away from them.
///
/// `Controller.injectTouch` picks `SOURCE_MOUSE` (0x2002) instead of
/// `SOURCE_TOUCHSCREEN` (0x1002) for these, and a mouse source does not produce
/// the fling velocities a finger does. Our pointers are numbered from zero.
abstract final class ScrcpyPointerId {
  static const int mouse = -1;
  static const int genericFinger = -2;
  static const int virtualMouse = -3;
  static const int virtualFinger = -4;
}

/// Wire length of an `INJECT_TOUCH_EVENT` message, including its type byte.
const int kScrcpyTouchMessageLength = 32;

/// Encodes a pressure in `0.0..1.0` the way `Binary.u16FixedPointToFloat`
/// decodes it: `0xFFFF` is exactly 1.0, everything else is `value / 65536`.
int encodePressure(double pressure) {
  if (pressure.isNaN) return 0;
  if (pressure >= 1.0) return 0xFFFF;
  if (pressure <= 0.0) return 0;
  return (pressure * 0x10000).round().clamp(0, 0xFFFE);
}

/// One touch to inject, in scrcpy's **video** coordinate space.
class ScrcpyTouchEvent {
  const ScrcpyTouchEvent({
    required this.action,
    required this.pointerId,
    required this.x,
    required this.y,
    required this.videoWidth,
    required this.videoHeight,
    this.pressure = 1.0,
    this.actionButton = 0,
    this.buttons = 0,
  });

  /// One of [AndroidMotionAction].
  final int action;

  /// Distinct per finger. scrcpy keys its `PointersState` on this.
  final int pointerId;

  final int x;
  final int y;

  /// scrcpy's current video size. Must match exactly or the event is dropped.
  final int videoWidth;
  final int videoHeight;

  /// 1.0 while the finger is down, 0.0 on release — the same convention
  /// Android's own touchscreen drivers use.
  final double pressure;

  /// Left at zero so `Controller.injectTouch` chooses `SOURCE_TOUCHSCREEN`:
  /// any non-primary button makes it choose `SOURCE_MOUSE` instead.
  final int actionButton;
  final int buttons;

  /// The 32 bytes on the wire.
  ///
  /// ```
  /// u8  type = 2        u8  action          u64 pointerId
  /// i32 x               i32 y               u16 videoWidth
  /// u16 videoHeight     u16 pressure        i32 actionButton
  /// i32 buttons
  /// ```
  Uint8List encode() {
    final bytes = Uint8List(kScrcpyTouchMessageLength);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, ScrcpyControlType.injectTouchEvent);
    view.setUint8(1, action);
    view.setUint64(2, pointerId);
    view.setInt32(10, x);
    view.setInt32(14, y);
    view.setUint16(18, videoWidth);
    view.setUint16(20, videoHeight);
    view.setUint16(22, encodePressure(pressure));
    view.setInt32(24, actionButton);
    view.setInt32(28, buttons);
    return bytes;
  }
}

/// The scrcpy control socket, opened alongside the video socket on the same
/// adb tunnel.
///
/// The server also *writes* on this socket (clipboard replies, UHID output), so
/// the incoming side is drained and discarded rather than ignored — an unread
/// socket eventually blocks the server's writer thread.
class ScrcpyControlConnection {
  ScrcpyControlConnection(this._socket, {AppLogger? logger})
    : _logger = logger ?? AppLogger.named('scrcpy-control') {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _incoming = _socket.listen(
      (data) {
        if (_replies.hasListener) _replies.add(data);
      },
      onDone: _markClosed,
      onError: (Object error) {
        _logger.warning('scrcpy control socket error: $error');
        _markClosed();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final AppLogger _logger;
  late final StreamSubscription<Uint8List> _incoming;
  final StreamController<Uint8List> _replies =
      StreamController<Uint8List>.broadcast();
  final Completer<void> _closed = Completer<void>();
  bool _open = true;

  /// Device messages coming back the other way (clipboard replies, UHID
  /// output). Broadcast, so with nobody listening the bytes are simply dropped
  /// — which is the normal case, and still drains the socket.
  Stream<Uint8List> get replies => _replies.stream;

  /// False once the socket has closed, from either end.
  bool get isOpen => _open;

  /// Completes when the socket closes. Useful as a liveness signal.
  Future<void> get closed => _closed.future;

  void _markClosed() {
    if (!_open) return;
    _open = false;
    if (!_closed.isCompleted) _closed.complete();
  }

  /// Writes one control message. Returns false if the socket is gone, which is
  /// the caller's cue to fall back to `adb shell input`.
  bool send(Uint8List message) {
    if (!_open) return false;
    try {
      _socket.add(message);
      return true;
    } catch (error) {
      _logger.warning('scrcpy control write failed: $error');
      _markClosed();
      return false;
    }
  }

  Future<void> close() async {
    _markClosed();
    await _incoming.cancel();
    await _replies.close();
    _socket.destroy();
  }
}
