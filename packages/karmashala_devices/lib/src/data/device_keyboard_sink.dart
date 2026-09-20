// Where a keystroke made in the live view is sent. The pane speaks one language
// — [DeviceKeyIntent] — and the sink decides what that means on the wire; the
// three are not equivalent, so the pane says which is in use.
//
// **Every one of them can refuse, and a refusal has to be legible.** A sink
// returns false from [DeviceKeyboardSink.send] and says why in `refusal`, which
// is per-keystroke: "iOS has no Page Down" and "a Cmd chord cannot be held" are
// not the same sentence, and the wrong one sends the user after a fiction.

import '../domain/device_keyboard.dart';
import '../domain/simulator_backend.dart';
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
  ),

  /// WebDriverAgent — text through XCUITest, named keys as HID presses, and no
  /// way to hold a modifier across either.
  webDriverAgent(
    'WebDriverAgent',
    false,
    'Ctrl, Alt and Cmd chords cannot be sent to iOS',
  );

  const DeviceKeyboardTransport(
    this.label,
    this.carriesModifiers,
    this.limitation,
  );

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

  /// Why the most recent [send] returned false, in the words the pane shows.
  /// `null` once a keystroke has gone through. A getter rather than a callback:
  /// the pane redraws on the same frame it calls [send] and needs it now.
  String? get refusal;
}

/// Wraps a keyboard sink so the live view learns that the user asked for
/// something — a keystroke is the same evidence as a tap.
class ObservedKeyboardSink implements DeviceKeyboardSink {
  ObservedKeyboardSink(this.inner, {required this.onInput});

  final DeviceKeyboardSink inner;
  final void Function() onInput;

  @override
  DeviceKeyboardTransport get transport => inner.transport;

  @override
  bool send(DeviceKeyIntent intent) {
    onInput();
    return inner.send(intent);
  }

  @override
  String? get refusal => inner.refusal;
}

/// Sends every keystroke straight down scrcpy's control socket.
class ScrcpyKeyboardSink implements DeviceKeyboardSink {
  ScrcpyKeyboardSink({required this.connection, this.onDropped});

  final ScrcpyControlConnection connection;

  /// Called when the socket has gone away, so the pane can fall back.
  final void Function()? onDropped;

  @override
  DeviceKeyboardTransport get transport =>
      DeviceKeyboardTransport.scrcpyControl;

  String? _refusal;

  @override
  String? get refusal => _refusal;

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
        // Not a key this transport cannot express — the socket itself has gone,
        // and the pane is about to fall back.
        _refusal = 'The control socket dropped, so that key went nowhere';
        onDropped?.call();
        return false;
      }
    }
    _refusal = null;
    return messages.isNotEmpty;
  }
}

/// Replays a keystroke through `adb shell input`. Only the *down* is acted on —
/// `input keyevent` synthesises a whole press — and a Ctrl/Alt/Meta chord is
/// refused rather than sent stripped of the modifier that gave it meaning.
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

  String? _refusal;

  @override
  String? get refusal => _refusal;

  @override
  bool send(DeviceKeyIntent intent) {
    switch (intent) {
      case DeviceTextIntent(:final text):
        _refusal = null;
        _run(adb.inputText(serial, text));
        return true;
      case DeviceKeycodeIntent():
        if (intent.action != AndroidKeyAction.down) return true;
        if (intent.needsChordModifier) {
          _refusal = transport.limitation;
          onUnsupported?.call(intent);
          return false;
        }
        _refusal = null;
        _run(adb.pressKeyCode(serial, intent.keyCode));
        return true;
    }
  }

  void _run(Future<void> action) {
    action.catchError((Object error) => onError?.call(error));
  }
}

/// Types into an iOS simulator through the [SimulatorBackend] seam. The two
/// halves take two different routes: characters go to [inputText] (XCUITest's
/// `typeText`), named keys to [pressKey] as real HID presses, because `typeText`
/// inserts an arrow key's private-use escape as a literal character instead.
/// Only the **down** is acted on, so nothing is ever left held.
class SimulatorKeyboardSink implements DeviceKeyboardSink {
  SimulatorKeyboardSink({
    required this.backend,
    required this.udid,
    this.onError,
  });

  final SimulatorBackend backend;
  final String udid;

  /// Where a failure that only shows up *after* the request went out is
  /// reported, so a dead WebDriverAgent says so once rather than once per key.
  final void Function(Object error)? onError;

  @override
  DeviceKeyboardTransport get transport =>
      DeviceKeyboardTransport.webDriverAgent;

  String? _refusal;

  @override
  String? get refusal => _refusal;

  @override
  bool send(DeviceKeyIntent intent) {
    switch (intent) {
      case DeviceTextIntent(:final text):
        _refusal = null;
        _run(backend.inputText(udid, text));
        return true;
      case DeviceKeycodeIntent(:final logicalKey):
        if (intent.action != AndroidKeyAction.down) return true;
        if (intent.needsChordModifier) {
          // A press is one request that returns with the key already back up,
          // so there is no moment at which a modifier is held alongside it.
          _refusal = transport.limitation;
          return false;
        }
        final key = logicalKey == null ? null : simulatorKeyFor(logicalKey);
        if (key == null) {
          // Named rather than generic: the user pressed a specific key and is
          // owed the specific reason it did nothing.
          final label = logicalKey?.keyLabel;
          _refusal = label == null || label.isEmpty
              ? 'iOS has no equivalent of that key'
              : 'iOS has no $label key';
          return false;
        }
        _refusal = null;
        _run(backend.pressKey(udid, key));
        return true;
    }
  }

  void _run(Future<void> action) {
    action.catchError((Object error) => onError?.call(error));
  }
}
