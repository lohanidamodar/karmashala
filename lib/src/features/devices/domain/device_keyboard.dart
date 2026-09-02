// Turning the desktop's keyboard into something a mirrored device understands.
//
// The owner's request was "scrcpy can also send keyboard events right, can we
// send keyboard events in live when actively focused there? with a option to
// stop sending keyboard?" — so: type into the mirror, and be able to stop.
//
// **Two devices, one translation.** This file was written for Android alone and
// now also serves an iOS simulator, so it is worth being exact about what is
// shared and what is not. The *split* below — printable text one way, named keys
// the other — is shared, because it follows from how desktop keyboards report
// characters rather than from anything Android does. The *vocabulary* is not:
// Android takes `KEYCODE_*` integers and a meta-state bitmask, while
// WebDriverAgent takes a string it feeds to `XCUIElement.typeText`, and there is
// no honest correspondence between an int and a private-use code point. So
// [DeviceKeycodeIntent] carries the originating [LogicalKeyboardKey] alongside
// the Android keycode, and [simulatorKeyFor] maps that key — not the keycode — onto
// what iOS understands. Round-tripping desktop → Android → iOS would make the
// second device's behaviour depend on the first device's numbering, which is
// exactly the kind of coupling that is invisible until it is wrong.
//
// **The split, and why.** Every key arriving here goes one of two ways:
//
// * A **printable character** with no Ctrl/Alt/Meta held is sent as *text*.
//   The device's own `KeyCharacterMap` then decides which key and which
//   modifier produce it (`Controller.injectText` → `KeyCharacterMap.getEvents`).
//   Sending `KEYCODE_2` + shift for `@` instead would be this side asserting
//   that the phone's layout matches the desktop's, which is false the moment
//   either is not US English — and it fails silently, typing `2`.
// * Everything else — Enter, Backspace, Tab, Escape, the arrows, Home/End,
//   Page Up/Down, the function keys, the Android hardware keys, and *any* key
//   pressed with Ctrl, Alt or Meta — is sent as a **keycode** with a meta
//   state. These have no character to compose (`KeyCharacterMap` cannot express
//   them at all), they need Android's repeat counter to hold down sensibly, and
//   a chord is only a chord if the modifier travels with it: Ctrl+A sent as
//   text is the letter "a" typed over the selection the user wanted.
//
// One thing worth being plain about, because "text" invites the wrong
// assumption: on scrcpy 4.1 **neither** path is an IME. `injectText` walks the
// string through the device's char map and injects ordinary hardware-keyboard
// `KeyEvent`s, exactly as the keycode path does. So the phone behaves as if a
// USB keyboard were plugged into it — autocorrect and the suggestion strip stay
// out of the way, and an app that only listens for IME commits (rare) sees
// nothing. That is the same bargain `adb shell input text` makes, so the
// fallback behaves the same way rather than differently.

import 'package:flutter/services.dart';

import 'simulator_backend.dart';

/// Android `KeyEvent.ACTION_*`.
abstract final class AndroidKeyAction {
  static const int down = 0;
  static const int up = 1;
}

/// Android `KeyEvent.META_*`.
///
/// Only the generic bits are sent, not the left/right ones: what a focused view
/// actually reads is `isCtrlPressed()`/`isShiftPressed()`, and those test
/// exactly these.
abstract final class AndroidMetaState {
  static const int none = 0;
  static const int shiftOn = 0x1;
  static const int altOn = 0x2;
  static const int ctrlOn = 0x1000;
  static const int metaOn = 0x10000;
  static const int capsLockOn = 0x100000;
  static const int numLockOn = 0x200000;
}

/// The AOSP `KEYCODE_*` values this app can send.
///
/// Numbers rather than names because both transports take numbers: scrcpy's
/// `INJECT_KEYCODE` carries an int, and `adb shell input keyevent` accepts one.
abstract final class AndroidKeyCode {
  // The hardware buttons, which have no desktop key at all.
  static const int home = 3;
  static const int back = 4;
  static const int appSwitch = 187;
  static const int power = 26;
  static const int volumeUp = 24;
  static const int volumeDown = 25;
  static const int menu = 82;
  static const int search = 84;

  // Editing and navigation.
  static const int del = 67; // Backspace.
  static const int forwardDel = 112; // Delete.
  static const int enter = 66;
  static const int tab = 61;
  static const int escape = 111;
  static const int space = 62;
  static const int insert = 124;
  static const int capsLock = 115;
  static const int dpadUp = 19;
  static const int dpadDown = 20;
  static const int dpadLeft = 21;
  static const int dpadRight = 22;
  static const int moveHome = 122;
  static const int moveEnd = 123;
  static const int pageUp = 92;
  static const int pageDown = 93;

  // Letters, reached only under a modifier — Ctrl+A, Ctrl+C, Ctrl+V…
  static const int a = 29;
  static const int k = 39;
  static const int w = 51;

  /// `KEYCODE_A` is 29 and the alphabet runs contiguously from there.
  static int letter(String character) =>
      a + (character.toLowerCase().codeUnitAt(0) - 0x61);

  /// `KEYCODE_0` is 7, and the digits run contiguously from there.
  static int digit(String character) => 7 + (character.codeUnitAt(0) - 0x30);

  /// `KEYCODE_F1` is 131.
  static int functionKey(int number) => 131 + (number - 1);
}

/// Modifiers held on the desktop when a key event arrived.
///
/// A value rather than a read of `HardwareKeyboard`, so the translation is a
/// pure function a test can drive without a binding.
class DesktopModifiers {
  const DesktopModifiers({
    this.shift = false,
    this.control = false,
    this.alt = false,
    this.meta = false,
    this.capsLock = false,
    this.numLock = false,
  });

  /// What is held right now, according to Flutter.
  factory DesktopModifiers.live() {
    final keyboard = HardwareKeyboard.instance;
    return DesktopModifiers(
      shift: keyboard.isShiftPressed,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
      capsLock: keyboard.lockModesEnabled.contains(KeyboardLockMode.capsLock),
      numLock: keyboard.lockModesEnabled.contains(KeyboardLockMode.numLock),
    );
  }

  final bool shift;
  final bool control;
  final bool alt;
  final bool meta;
  final bool capsLock;
  final bool numLock;

  /// Whether a modifier is held that changes what a *character* key means.
  ///
  /// Shift is deliberately not one of them: it has already done its work by the
  /// time Flutter reports the character, and treating it as a chord would send
  /// `KEYCODE_A` + shift for a capital A instead of the letter itself.
  bool get hasChordModifier => control || alt || meta;

  int get androidMetaState =>
      (shift ? AndroidMetaState.shiftOn : 0) |
      (alt ? AndroidMetaState.altOn : 0) |
      (control ? AndroidMetaState.ctrlOn : 0) |
      (meta ? AndroidMetaState.metaOn : 0) |
      (capsLock ? AndroidMetaState.capsLockOn : 0) |
      (numLock ? AndroidMetaState.numLockOn : 0);
}

/// What one desktop key event becomes on the device.
sealed class DeviceKeyIntent {
  const DeviceKeyIntent();
}

/// Characters for the device to type. See the file comment for why this is the
/// preferred path for anything printable.
final class DeviceTextIntent extends DeviceKeyIntent {
  const DeviceTextIntent(this.text);

  final String text;

  @override
  String toString() => 'DeviceTextIntent("$text")';
}

/// One Android key event, down or up.
final class DeviceKeycodeIntent extends DeviceKeyIntent {
  const DeviceKeycodeIntent({
    required this.action,
    required this.keyCode,
    this.logicalKey,
    this.repeat = 0,
    this.metaState = AndroidMetaState.none,
  });

  final int action;
  final int keyCode;
  final int repeat;
  final int metaState;

  /// The desktop key this came from, kept so a sink that does not speak Android
  /// can still say which key was pressed.
  ///
  /// Nullable rather than required because the intent is also constructed
  /// straight from a keycode in tests and in [DeviceKeyTranslator.releaseAll]'s
  /// older callers; a sink that needs it treats `null` as "no equivalent" and
  /// refuses, which is the same answer it gives for a key it cannot map.
  final LogicalKeyboardKey? logicalKey;

  /// Whether this needs a modifier the transport may not be able to carry.
  ///
  /// Shift does not count: the printable path has already applied it, and a
  /// shifted arrow is a selection Android reads off the keycode alone.
  bool get needsChordModifier =>
      metaState &
          (AndroidMetaState.ctrlOn |
              AndroidMetaState.altOn |
              AndroidMetaState.metaOn) !=
      0;

  @override
  String toString() =>
      'DeviceKeycodeIntent(action: $action, keyCode: $keyCode, '
      'repeat: $repeat, metaState: $metaState)';
}

/// A modifier + key combination, described without reaching for the widget
/// layer's `SingleActivator` — this is the domain, and the pane can build an
/// activator from it if it ever needs one.
class DeviceKeyChord {
  const DeviceKeyChord({
    required this.trigger,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });

  final LogicalKeyboardKey trigger;
  final bool control;
  final bool alt;
  final bool shift;
}

/// The chord that turns forwarding on and off, and the one chord that is never
/// sent to the device.
///
/// It has to be reserved rather than merely handled first: with forwarding on,
/// the pane swallows every shortcut the app has — including the ones that would
/// move focus away — so a user who armed it and then reached for the keyboard
/// would have no way back. Ctrl+Alt+K is unclaimed by Karmashala (its Ctrl+K is
/// the command palette, which *is* forwarded, deliberately), unclaimed by
/// Android, and reachable one-handed.
const DeviceKeyChord kDeviceKeyboardEscape = DeviceKeyChord(
  trigger: LogicalKeyboardKey.keyK,
  control: true,
  alt: true,
);

/// [kDeviceKeyboardEscape] as the user should read it. Written wherever the
/// forwarding state is shown, because a hidden escape hatch is not one.
const String kDeviceKeyboardEscapeLabel = 'Ctrl+Alt+K';

/// Keys that are only ever a modifier. Android carries their state on every
/// other event, so forwarding them on their own does nothing useful.
// `final`, not `const`: `LogicalKeyboardKey` overrides `==`, and Dart refuses
// such a value as a key in a constant collection.
final Set<LogicalKeyboardKey> _modifierKeys = {
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.fn,
};

/// Desktop keys with a fixed Android keycode.
final Map<LogicalKeyboardKey, int> _keyCodes = {
  LogicalKeyboardKey.backspace: AndroidKeyCode.del,
  LogicalKeyboardKey.delete: AndroidKeyCode.forwardDel,
  LogicalKeyboardKey.enter: AndroidKeyCode.enter,
  LogicalKeyboardKey.numpadEnter: AndroidKeyCode.enter,
  LogicalKeyboardKey.tab: AndroidKeyCode.tab,
  LogicalKeyboardKey.escape: AndroidKeyCode.escape,
  LogicalKeyboardKey.space: AndroidKeyCode.space,
  LogicalKeyboardKey.insert: AndroidKeyCode.insert,
  LogicalKeyboardKey.capsLock: AndroidKeyCode.capsLock,
  LogicalKeyboardKey.arrowUp: AndroidKeyCode.dpadUp,
  LogicalKeyboardKey.arrowDown: AndroidKeyCode.dpadDown,
  LogicalKeyboardKey.arrowLeft: AndroidKeyCode.dpadLeft,
  LogicalKeyboardKey.arrowRight: AndroidKeyCode.dpadRight,
  LogicalKeyboardKey.home: AndroidKeyCode.moveHome,
  LogicalKeyboardKey.end: AndroidKeyCode.moveEnd,
  LogicalKeyboardKey.pageUp: AndroidKeyCode.pageUp,
  LogicalKeyboardKey.pageDown: AndroidKeyCode.pageDown,
  LogicalKeyboardKey.contextMenu: AndroidKeyCode.menu,
  LogicalKeyboardKey.browserSearch: AndroidKeyCode.search,
  LogicalKeyboardKey.goBack: AndroidKeyCode.back,
  LogicalKeyboardKey.audioVolumeUp: AndroidKeyCode.volumeUp,
  LogicalKeyboardKey.audioVolumeDown: AndroidKeyCode.volumeDown,
  // Punctuation, reached only under a modifier — Ctrl+- and Ctrl+= are zoom in
  // a browser on the phone as much as they are here.
  LogicalKeyboardKey.minus: 69,
  LogicalKeyboardKey.equal: 70,
  LogicalKeyboardKey.bracketLeft: 71,
  LogicalKeyboardKey.bracketRight: 72,
  LogicalKeyboardKey.backslash: 73,
  LogicalKeyboardKey.semicolon: 74,
  LogicalKeyboardKey.quote: 75,
  LogicalKeyboardKey.backquote: 68,
  LogicalKeyboardKey.comma: 55,
  LogicalKeyboardKey.period: 56,
  LogicalKeyboardKey.slash: 76,
};

/// The twelve function keys, which are contiguous on both sides.
final Map<LogicalKeyboardKey, int> _functionKeys = {
  LogicalKeyboardKey.f1: 131,
  LogicalKeyboardKey.f2: 132,
  LogicalKeyboardKey.f3: 133,
  LogicalKeyboardKey.f4: 134,
  LogicalKeyboardKey.f5: 135,
  LogicalKeyboardKey.f6: 136,
  LogicalKeyboardKey.f7: 137,
  LogicalKeyboardKey.f8: 138,
  LogicalKeyboardKey.f9: 139,
  LogicalKeyboardKey.f10: 140,
  LogicalKeyboardKey.f11: 141,
  LogicalKeyboardKey.f12: 142,
};

/// The Android keycode for [key], or `null` if there is not one.
int? androidKeyCodeFor(LogicalKeyboardKey key) {
  final fixed = _keyCodes[key] ?? _functionKeys[key];
  if (fixed != null) return fixed;
  final label = key.keyLabel;
  if (label.length == 1) {
    final unit = label.toLowerCase().codeUnitAt(0);
    if (unit >= 0x61 && unit <= 0x7A) return AndroidKeyCode.letter(label);
    if (unit >= 0x30 && unit <= 0x39) return AndroidKeyCode.digit(label);
  }
  return null;
}

/// Desktop keys that exist on an iOS keyboard too.
///
/// Deliberately shorter than [_keyCodes], and the gaps are the point rather
/// than an unfinished table:
///
/// * **Back, Menu, Search, Volume** are Android hardware keys. iOS draws its own
///   back button inside the app and has no system one, so pressing a
///   best-effort substitute would silently do the wrong thing — the same
///   reasoning that makes `SimulatorButton.forDeviceKey` partial.
/// * **Punctuation** is absent because it is only ever reached here under a
///   modifier, and a modifier cannot be held across a key press through this
///   transport at all (see [SimulatorKey]). Unmodified punctuation is a
///   character, and characters go down the text path.
///
/// Anything missing is refused out loud by the sink rather than approximated.
final Map<LogicalKeyboardKey, SimulatorKey> _simulatorKeys = {
  LogicalKeyboardKey.backspace: SimulatorKey.backspace,
  LogicalKeyboardKey.delete: SimulatorKey.forwardDelete,
  LogicalKeyboardKey.enter: SimulatorKey.returnKey,
  LogicalKeyboardKey.numpadEnter: SimulatorKey.returnKey,
  LogicalKeyboardKey.tab: SimulatorKey.tab,
  LogicalKeyboardKey.escape: SimulatorKey.escape,
  LogicalKeyboardKey.insert: SimulatorKey.insert,
  LogicalKeyboardKey.capsLock: SimulatorKey.capsLock,
  LogicalKeyboardKey.arrowUp: SimulatorKey.arrowUp,
  LogicalKeyboardKey.arrowDown: SimulatorKey.arrowDown,
  LogicalKeyboardKey.arrowLeft: SimulatorKey.arrowLeft,
  LogicalKeyboardKey.arrowRight: SimulatorKey.arrowRight,
  LogicalKeyboardKey.home: SimulatorKey.home,
  LogicalKeyboardKey.end: SimulatorKey.end,
  LogicalKeyboardKey.pageUp: SimulatorKey.pageUp,
  LogicalKeyboardKey.pageDown: SimulatorKey.pageDown,
  LogicalKeyboardKey.f1: SimulatorKey.f1,
  LogicalKeyboardKey.f2: SimulatorKey.f2,
  LogicalKeyboardKey.f3: SimulatorKey.f3,
  LogicalKeyboardKey.f4: SimulatorKey.f4,
  LogicalKeyboardKey.f5: SimulatorKey.f5,
  LogicalKeyboardKey.f6: SimulatorKey.f6,
  LogicalKeyboardKey.f7: SimulatorKey.f7,
  LogicalKeyboardKey.f8: SimulatorKey.f8,
  LogicalKeyboardKey.f9: SimulatorKey.f9,
  LogicalKeyboardKey.f10: SimulatorKey.f10,
  LogicalKeyboardKey.f11: SimulatorKey.f11,
  LogicalKeyboardKey.f12: SimulatorKey.f12,
};

/// The iOS key for [key], or `null` if iOS has no such key.
///
/// Note there is no letter or digit fallback, unlike [androidKeyCodeFor]. On
/// Android those exist so a *chord* can name its trigger — `KEYCODE_A` for
/// Ctrl+A — and this transport cannot send a chord, so a letter arriving here
/// would only ever be a letter, which the text path already types.
SimulatorKey? simulatorKeyFor(LogicalKeyboardKey key) => _simulatorKeys[key];

/// Translates one desktop keyboard into one Android keyboard.
///
/// Stateful for two reasons, both of which are bugs if they are skipped:
///
/// * A key sent as *text* on the way down must not send an `ACTION_UP` on the
///   way back, because no `ACTION_DOWN` for that keycode was ever sent. A stray
///   up is not ignored by Android — it is delivered.
/// * A key still held when the pane loses focus has to be lifted explicitly
///   ([releaseAll]), or the device believes it is held forever. An arrow key
///   left down scrolls a list to the bottom on its own.
class DeviceKeyTranslator {
  /// Physical keys currently down *as a keycode*, and their repeat counters.
  ///
  /// The logical key is kept beside the keycode so [releaseAll] can build a
  /// complete intent: a release goes out with no key event in hand, and a sink
  /// that maps by logical key would otherwise be handed a keycode it cannot
  /// read and refuse to lift a key the device thinks is held.
  final Map<
    PhysicalKeyboardKey,
    ({int keyCode, int repeat, LogicalKeyboardKey logicalKey})
  >
  _down = {};

  /// The event's Android form, or `null` when nothing should be sent.
  DeviceKeyIntent? translate(KeyEvent event, DesktopModifiers modifiers) {
    // Reserved before anything else: this is the way back out, and it must not
    // be reachable by any path that could send it to the device.
    if (isEscapeChord(event, modifiers)) return null;

    if (_modifierKeys.contains(event.logicalKey)) return null;

    if (event is KeyUpEvent) {
      final held = _down.remove(event.physicalKey);
      if (held == null) return null;
      return DeviceKeycodeIntent(
        action: AndroidKeyAction.up,
        keyCode: held.keyCode,
        logicalKey: held.logicalKey,
        metaState: modifiers.androidMetaState,
      );
    }

    final character = event.character;
    final printable =
        !modifiers.hasChordModifier &&
        character != null &&
        character.isNotEmpty &&
        !_isControlCharacter(character);
    if (printable) return DeviceTextIntent(character);

    final keyCode = androidKeyCodeFor(event.logicalKey);
    if (keyCode == null) return null;

    final previous = _down[event.physicalKey];
    final repeat = event is KeyRepeatEvent ? (previous?.repeat ?? 0) + 1 : 0;
    _down[event.physicalKey] = (
      keyCode: keyCode,
      repeat: repeat,
      logicalKey: event.logicalKey,
    );
    return DeviceKeycodeIntent(
      action: AndroidKeyAction.down,
      keyCode: keyCode,
      logicalKey: event.logicalKey,
      repeat: repeat,
      metaState: modifiers.androidMetaState,
    );
  }

  /// Lifts every key the device still believes is held. Call on focus loss,
  /// when forwarding is turned off, and when the session ends.
  List<DeviceKeycodeIntent> releaseAll() {
    final released = [
      for (final held in _down.values)
        DeviceKeycodeIntent(
          action: AndroidKeyAction.up,
          keyCode: held.keyCode,
          logicalKey: held.logicalKey,
        ),
    ];
    _down.clear();
    return released;
  }

  /// Whether anything is still held.
  bool get hasKeysDown => _down.isNotEmpty;

  /// Whether [event] is [kDeviceKeyboardEscape], down or up.
  ///
  /// Both halves are matched: forwarding the *release* of a chord whose press
  /// was swallowed would send an unpaired `ACTION_UP`.
  static bool isEscapeChord(KeyEvent event, DesktopModifiers modifiers) =>
      event.logicalKey == kDeviceKeyboardEscape.trigger &&
      modifiers.control &&
      modifiers.alt &&
      !modifiers.meta;

  /// A character Flutter reports for a key that is not really text — `\n` for
  /// Enter, `\t` for Tab, `\x08` for Backspace, depending on the platform.
  /// Typing a newline is not the same as pressing Enter: a search field submits
  /// on one and ignores the other.
  static bool _isControlCharacter(String character) {
    final unit = character.codeUnitAt(0);
    return unit < 0x20 || unit == 0x7F;
  }
}
