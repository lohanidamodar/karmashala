// scrcpy's control protocol: the client→server half, and the socket that carries
// it. Every constant below was read out of the scrcpy-server jar this app
// deploys, not from documentation. The width/height in a touch message must
// equal scrcpy's *video* size, or `PositionMapper.map` drops it without a word.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

/// Control-message type ids, read from `ControlMessageReader.read`'s
/// packed-switch in the deployed jar.
abstract final class ScrcpyControlType {
  static const int injectKeycode = 0;
  static const int injectText = 1;
  static const int injectTouchEvent = 2;
  static const int injectScrollEvent = 3;
  static const int backOrScreenOn = 4;

  /// Ask the device for its clipboard; the reply is a `TYPE_CLIPBOARD` device
  /// message on the same socket — see `scrcpy_device_message.dart`.
  static const int getClipboard = 8;

  /// Put text on the device's clipboard. Acknowledged by a `TYPE_ACK_CLIPBOARD`
  /// device message carrying the sequence that was sent.
  static const int setClipboard = 9;

  /// Restart video capture: a fresh codec config and keyframe, nothing torn
  /// down. 17 was read out of the deployed jar — the numbering has moved between
  /// releases, and a wrong byte here is a valid message meaning something else.
  static const int resetVideo = 17;
}

/// The whole `RESET_VIDEO` message: the type byte and nothing else. A payload
/// after it would be read as the next message's type and desync the socket.
Uint8List encodeResetVideo() =>
    Uint8List.fromList(const [ScrcpyControlType.resetVideo]);

/// The `MotionEvent.ACTION_*` values a touch message may carry. Only these four:
/// `Controller.injectTouch` derives the pointer-index variants itself.
abstract final class AndroidMotionAction {
  static const int down = 0;
  static const int up = 1;
  static const int move = 2;
  static const int cancel = 3;
}

/// Pointer ids scrcpy treats specially, listed so we can stay away from them:
/// they get `SOURCE_MOUSE`, which does not produce a finger's fling velocities.
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

/// Wire length of an `INJECT_KEYCODE` message, including its type byte.
const int kScrcpyKeycodeMessageLength = 14;

/// The most UTF-8 bytes one `INJECT_TEXT` may carry. A longer message is refused
/// and then desynchronises the socket; longer text goes through
/// [splitForInjectText].
const int kScrcpyInjectTextMaxBytes = 300;

/// One `INJECT_KEYCODE` message: a real Android `KeyEvent` for the device.
///
/// ```
/// u8  type = 0        u8  action          i32 keyCode
/// i32 repeat          i32 metaState
/// ```
class ScrcpyKeycodeEvent {
  const ScrcpyKeycodeEvent({
    required this.action,
    required this.keyCode,
    this.repeat = 0,
    this.metaState = 0,
  });

  /// `KeyEvent.ACTION_DOWN` (0) or `ACTION_UP` (1).
  final int action;

  /// An Android `KEYCODE_*` value.
  final int keyCode;

  /// Android's auto-repeat counter. A held key must raise this rather than
  /// resend zero: a view that distinguishes a repeat from a fresh press —
  /// a long-press handler, say — reads exactly this field.
  final int repeat;

  /// `KeyEvent.META_*` bits. This is what makes Ctrl+A a select-all rather
  /// than the letter A.
  final int metaState;

  Uint8List encode() {
    final bytes = Uint8List(kScrcpyKeycodeMessageLength);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, ScrcpyControlType.injectKeycode);
    view.setUint8(1, action);
    view.setInt32(2, keyCode);
    view.setInt32(6, repeat);
    view.setInt32(10, metaState);
    return bytes;
  }
}

/// One `INJECT_TEXT` message: characters for the device to type.
///
/// ```
/// u8  type = 1        u32 utf8 length     u8[length] utf-8
/// ```
///
/// Not an IME commit: the *device's* char map decides which key produces `@`,
/// rather than this side assuming the two keyboards share a layout.
class ScrcpyTextEvent {
  const ScrcpyTextEvent(this.text);

  final String text;

  Uint8List encode() {
    final utf8Bytes = utf8.encode(text);
    if (utf8Bytes.isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
    if (utf8Bytes.length > kScrcpyInjectTextMaxBytes) {
      throw ArgumentError.value(
        text,
        'text',
        'longer than $kScrcpyInjectTextMaxBytes bytes; '
            'use splitForInjectText',
      );
    }
    final bytes = Uint8List(5 + utf8Bytes.length);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, ScrcpyControlType.injectText);
    view.setUint32(1, utf8Bytes.length);
    bytes.setRange(5, bytes.length, utf8Bytes);
    return bytes;
  }
}

/// [text] cut into pieces each of which fits one `INJECT_TEXT`. Cut on
/// **character** boundaries: half a UTF-8 sequence pastes as mojibake.
List<String> splitForInjectText(String text) {
  if (text.isEmpty) return const [];
  final chunks = <String>[];
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    final size = utf8.encode(character).length;
    if (bytes + size > kScrcpyInjectTextMaxBytes) {
      chunks.add(buffer.toString());
      buffer.clear();
      bytes = 0;
    }
    buffer.write(character);
    bytes += size;
  }
  if (buffer.isNotEmpty) chunks.add(buffer.toString());
  return chunks;
}

/// The two-way half of scrcpy's control protocol, without the socket — a seam so
/// the sequence matching and timeout policy can be tested off a real phone.
abstract interface class ScrcpyControlChannel {
  /// Writes one control message. False when the socket is gone.
  bool send(Uint8List message);

  /// Messages the device sent back. Broadcast, so with nobody listening the
  /// bytes are dropped — which still drains the socket.
  Stream<Uint8List> get replies;

  bool get isOpen;
}

/// The scrcpy control socket, opened alongside the video socket on the same adb
/// tunnel. The incoming side is drained: an unread socket blocks the server.
class ScrcpyControlConnection implements ScrcpyControlChannel {
  ScrcpyControlConnection(this._socket, {Logger? logger})
    : _logger = logger ?? Logger('scrcpy-control') {
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
  final Logger _logger;
  late final StreamSubscription<Uint8List> _incoming;
  final StreamController<Uint8List> _replies =
      StreamController<Uint8List>.broadcast();
  final Completer<void> _closed = Completer<void>();
  bool _open = true;

  /// Device messages coming back the other way. Broadcast, so with nobody
  /// listening the bytes are dropped — which still drains the socket.
  @override
  Stream<Uint8List> get replies => _replies.stream;

  /// False once the socket has closed, from either end.
  @override
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
  @override
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

// The device→host direction works because of a *permission*, not a protocol:
// scrcpy-server runs as the shell uid, and `com.android.shell` holds
// READ_CLIPBOARD_IN_BACKGROUND. That is a fact about the device, so this build
// reports what the device answered — see `DeviceClipboardRead`.

/// What the server should do to the device's selection before reading it. Only
/// [none] is sent: [copy] and [cut] inject Ctrl+C and would edit the document.
abstract final class ScrcpyCopyKey {
  static const int none = 0;
  static const int copy = 1;
  static const int cut = 2;
}

/// The whole `GET_CLIPBOARD` message: the type byte and a copy-key byte. A spare
/// byte is read as the next message's type and the socket never recovers.
Uint8List encodeGetClipboard({int copyKey = ScrcpyCopyKey.none}) =>
    Uint8List.fromList([ScrcpyControlType.getClipboard, copyKey]);

/// The most UTF-8 bytes one `SET_CLIPBOARD` may carry. An over-long message is
/// refused and desyncs the socket, so [ScrcpySetClipboardMessage.encode] throws.
const int kScrcpyClipboardTextMaxBytes = 262130;

/// One `SET_CLIPBOARD` message: text for the device's clipboard.
///
/// ```
/// u8  type = 9        i64 sequence        u8  paste
/// u32 utf8 length     u8[length] utf-8
/// ```
class ScrcpySetClipboardMessage {
  const ScrcpySetClipboardMessage({
    required this.sequence,
    required this.text,
    this.paste = false,
  });

  /// Echoed back in an `ACK_CLIPBOARD`, and the only way to tell this write's
  /// acknowledgement from one for a write that already timed out. Never zero,
  /// which the server reads as "do not acknowledge".
  final int sequence;

  final String text;

  /// Whether the server should paste after setting the clipboard. False: putting
  /// text on a phone's clipboard is not permission to type it into what is open.
  final bool paste;

  Uint8List encode() {
    final utf8Bytes = utf8.encode(text);
    if (utf8Bytes.length > kScrcpyClipboardTextMaxBytes) {
      throw ArgumentError.value(
        utf8Bytes.length,
        'text',
        'longer than $kScrcpyClipboardTextMaxBytes UTF-8 bytes; the server '
            'refuses the message and the control socket then desynchronises',
      );
    }
    final bytes = Uint8List(14 + utf8Bytes.length);
    final view = ByteData.sublistView(bytes);
    view.setUint8(0, ScrcpyControlType.setClipboard);
    view.setInt64(1, sequence);
    view.setUint8(9, paste ? 1 : 0);
    view.setUint32(10, utf8Bytes.length);
    bytes.setRange(14, bytes.length, utf8Bytes);
    return bytes;
  }
}
