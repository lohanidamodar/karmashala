// Where a keystroke made in the live view is sent.
//
// The same shape as `device_gesture_sink.dart` next door, and for the same
// reason: the pane speaks one language — [DeviceKeyIntent] — and the sink
// decides what that means on the wire. There are three, and they are not
// equivalent, so the pane says which is in use.
//
// * [ScrcpyKeyboardSink] writes a control message per event: sub-10 ms, carries
//   Android's meta state, and can express a key being *held*.
// * [AdbKeyboardSink] shells out to `adb shell input`, ~200 ms per key, and
//   cannot express a modifier at all — `input keyevent` has no meta argument.
//   Rather than send a bare `KEYCODE_A` for Ctrl+A (which would type "a" over
//   the selection the user wanted), it refuses the chord and says so.
// * [SimulatorKeyboardSink] drives an iOS simulator through the backend seam,
//   splitting the two halves across two different mechanisms because on iOS
//   they genuinely are different mechanisms — see the class doc.
//
// **Every one of them can refuse, and a refusal has to be legible.** A sink
// says *no* by returning false from [DeviceKeyboardSink.send], and says *why*
// in [DeviceKeyboardSink.refusal]. The reason is per-sink and per-keystroke
// rather than a fixed line per transport, because the same sink refuses
// different keys for different reasons: "iOS has no Page Down" and "a Cmd chord
// cannot be held across a key press" are not the same sentence, and showing the
// wrong one is a worse failure than showing none — it sends the user looking
// for a modifier problem they do not have.

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

  /// Why the most recent [send] returned false, in the words the pane shows.
  ///
  /// `null` once a keystroke has gone through, so the bar stops accusing the
  /// transport of a fault it has recovered from.
  ///
  /// A getter rather than a callback because the pane already redraws on the
  /// same frame it calls [send]: it needs the answer *now*, not next tick, and
  /// a callback would have to be threaded through every place a sink is built.
  String? get refusal;
}

/// Wraps a keyboard sink so the live view learns that the user asked for
/// something. See [ObservedGestureSink]; a keystroke is the same kind of
/// evidence as a tap.
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
  DeviceKeyboardTransport get transport => DeviceKeyboardTransport.scrcpyControl;

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
        // Not a key this transport cannot express — the socket itself has gone.
        // Named as such, because "that key could not be sent" would read as a
        // limit of the keyboard rather than a lost connection the pane is about
        // to fall back from.
        _refusal = 'The control socket dropped, so that key went nowhere';
        onDropped?.call();
        return false;
      }
    }
    _refusal = null;
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

/// Types into an iOS simulator through the [SimulatorBackend] seam.
///
/// **The two halves take two different routes, and that is not an
/// optimisation.** Measured against WebDriverAgent 16.11.4 on an iOS 18.2
/// simulator:
///
/// * Characters go to [SimulatorBackend.inputText], which is XCUITest's
///   `typeText`. Anything the iOS keyboard can produce travels as itself —
///   accents, emoji, whole strings at once — so there is no character table
///   here and nothing to refuse.
/// * Named keys go to [SimulatorBackend.pressKey], which is a real HID key
///   press. They must **not** go through `typeText`: posting the
///   XCUIKeyboardKey escape for Left Arrow inserts `U+F702` into the focused
///   field as a literal character instead of moving the caret: "hell" became
///   "hell" with an invisible `U+F702` appended. Typing private-use garbage
///   into the user's text field is a worse failure than refusing, and a
///   silent one.
///
/// Like [AdbKeyboardSink], only the **down** is acted on: a press is one whole
/// down-and-up, so replaying it on the release would type every key twice.
/// Nothing is ever left held, which is why [DeviceKeyTranslator.releaseAll]'s
/// up-intents can simply be dropped here.
class SimulatorKeyboardSink implements DeviceKeyboardSink {
  SimulatorKeyboardSink({
    required this.backend,
    required this.udid,
    this.onError,
  });

  final SimulatorBackend backend;
  final String udid;

  /// Where a failure that only shows up *after* the request went out is
  /// reported. The same channel `SimulatorGestureSink` uses, so a WebDriverAgent
  /// that died mid-session says so once rather than once per key.
  final void Function(Object error)? onError;

  @override
  DeviceKeyboardTransport get transport => DeviceKeyboardTransport.webDriverAgent;

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
