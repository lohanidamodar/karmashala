// Where a keystroke made in the live view is sent.
//
// The same shape as `device_gesture_sink.dart` next door, and for the same
// reason: the pane speaks one language — [DeviceKeyIntent] — and the sink
// decides what that means on the wire. There are two, and they are not
// equivalent, so the pane says which is in use.
//
// * [ScrcpyKeyboardSink] writes a control message per event: sub-10 ms, carries
//   Android's meta state, and can express a key being *held*.
// * [AdbKeyboardSink] shells out to `adb shell input`, ~200 ms per key, and
//   cannot express a modifier at all — `input keyevent` has no meta argument.
//   Rather than send a bare `KEYCODE_A` for Ctrl+A (which would type "a" over
//   the selection the user wanted), it refuses the chord and says so.

import '../domain/device_keyboard.dart';
import 'adb_service.dart';
import 'scrcpy_control.dart';

/// How the live view is typing on the device right now.
enum DeviceKeyboardTransport {
  /// scrcpy's control socket — real key events, meta state included.
  scrcpyControl('Control socket', true, null),

  /// `adb shell input` — one synthesised press per key, no modifiers.
  adbInput(
    'adb input',
    false,
    'Ctrl, Alt and Meta chords cannot be sent over adb input',
  );

  const DeviceKeyboardTransport(this.label, this.carriesModifiers, this.limitation);

  final String label;

  /// Whether a Ctrl/Alt/Meta chord survives this transport.
  final bool carriesModifiers;

  /// What this transport cannot do, in the words the pane shows. `null` when
  /// there is nothing to warn about.
  final String? limitation;
}

/// Receives translated keystrokes from the live view.
abstract interface class DeviceKeyboardSink {
  DeviceKeyboardTransport get transport;

  /// Sends [intent]. Returns false when it could not be delivered — the caller
  /// surfaces that rather than letting a keystroke disappear.
  bool send(DeviceKeyIntent intent);
}

/// Sends every keystroke straight down scrcpy's control socket.
class ScrcpyKeyboardSink implements DeviceKeyboardSink {
  ScrcpyKeyboardSink({required this.connection, this.onDropped});

  final ScrcpyControlConnection connection;

  /// Called when the socket has gone away, so the pane can fall back.
  final void Function()? onDropped;

  @override
  DeviceKeyboardTransport get transport => DeviceKeyboardTransport.scrcpyControl;

  @override
  bool send(DeviceKeyIntent intent) {
    final messages = switch (intent) {
      // Split, because the server allocates the declared length and refuses
      // anything over its cap — and then desynchronises on the next message.
      DeviceTextIntent(:final text) => [
        for (final chunk in splitForInjectText(text))
          ScrcpyTextEvent(chunk).encode(),
      ],
      DeviceKeycodeIntent(
        :final action,
        :final keyCode,
        :final repeat,
        :final metaState,
      ) =>
        [
          ScrcpyKeycodeEvent(
            action: action,
            keyCode: keyCode,
            repeat: repeat,
            metaState: metaState,
          ).encode(),
        ],
    };
    for (final message in messages) {
      if (!connection.send(message)) {
        onDropped?.call();
        return false;
      }
    }
    return messages.isNotEmpty;
  }
}

/// Replays a keystroke through `adb shell input`.
///
/// Honest about what it cannot do. `input keyevent` synthesises a whole press,
/// so only the *down* is acted on — sending it again on the release would type
/// every key twice — and a Ctrl/Alt/Meta chord is refused rather than sent
/// stripped of the modifier that gave it its meaning.
class AdbKeyboardSink implements DeviceKeyboardSink {
  AdbKeyboardSink({
    required this.adb,
    required this.serial,
    this.onError,
    this.onUnsupported,
  });

  final AdbService adb;
  final String serial;
  final void Function(Object error)? onError;

  /// Called with a chord this transport cannot express, so the pane can tell
  /// the user instead of leaving them wondering why nothing happened.
  final void Function(DeviceKeycodeIntent intent)? onUnsupported;

  @override
  DeviceKeyboardTransport get transport => DeviceKeyboardTransport.adbInput;

  @override
  bool send(DeviceKeyIntent intent) {
    switch (intent) {
      case DeviceTextIntent(:final text):
        _run(adb.inputText(serial, text));
        return true;
      case DeviceKeycodeIntent():
        if (intent.action != AndroidKeyAction.down) return true;
        if (intent.needsChordModifier) {
          onUnsupported?.call(intent);
          return false;
        }
        _run(adb.pressKeyCode(serial, intent.keyCode));
        return true;
    }
  }

  void _run(Future<void> action) {
    action.catchError((Object error) => onError?.call(error));
  }
}
