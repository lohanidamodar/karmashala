// Turning the desktop's keyboard into something a mirrored device understands.
// Printable characters with no Ctrl/Alt/Meta go as *text*, so the device's own
// `KeyCharacterMap` picks the key; everything else goes as a keycode with a meta
// state, because a chord is only a chord if the modifier travels with it.

import 'simulator_backend.dart';

/// A desktop keyboard key, identified the way Flutter's `DesktopKey` does.
/// A value, not the Flutter type: none of this needs a widget or a binding.
class DesktopKey {
  const DesktopKey(this.keyId);

  /// Flutter's `DesktopKey.keyId`: a Unicode code point for a printable
  /// key, or a value in one of the reserved planes above `0xFFFFFFFF`.
  final int keyId;

  /// 'A', '2', 'Backspace', 'Arrow Up' — or empty for a key with no name here.
  String get keyLabel =>
      (keyId >> 32) == 0 ? String.fromCharCode(keyId).toUpperCase() : (_labels[keyId] ?? '');

  @override
  bool operator ==(Object other) => other is DesktopKey && other.keyId == keyId;

  @override
  int get hashCode => keyId.hashCode;

  @override
  String toString() =>
      'DesktopKey(0x${keyId.toRadixString(16)}${keyLabel.isEmpty ? '' : ', $keyLabel'})';

  static const control = DesktopKey(0x002000001f0);
  static const controlLeft = DesktopKey(0x00200000100);
  static const controlRight = DesktopKey(0x00200000101);
  static const shift = DesktopKey(0x002000001f2);
  static const shiftLeft = DesktopKey(0x00200000102);
  static const shiftRight = DesktopKey(0x00200000103);
  static const alt = DesktopKey(0x002000001f4);
  static const altLeft = DesktopKey(0x00200000104);
  static const altRight = DesktopKey(0x00200000105);
  static const meta = DesktopKey(0x002000001f6);
  static const metaLeft = DesktopKey(0x00200000106);
  static const metaRight = DesktopKey(0x00200000107);
  static const fn = DesktopKey(0x00100000106);

  static const backspace = DesktopKey(0x00100000008);
  static const delete = DesktopKey(0x0010000007f);
  static const enter = DesktopKey(0x0010000000d);
  static const numpadEnter = DesktopKey(0x0020000020d);
  static const tab = DesktopKey(0x00100000009);
  static const escape = DesktopKey(0x0010000001b);
  static const space = DesktopKey(0x00000000020);
  static const insert = DesktopKey(0x00100000407);
  static const capsLock = DesktopKey(0x00100000104);
  static const arrowUp = DesktopKey(0x00100000304);
  static const arrowDown = DesktopKey(0x00100000301);
  static const arrowLeft = DesktopKey(0x00100000302);
  static const arrowRight = DesktopKey(0x00100000303);
  static const home = DesktopKey(0x00100000306);
  static const end = DesktopKey(0x00100000305);
  static const pageUp = DesktopKey(0x00100000308);
  static const pageDown = DesktopKey(0x00100000307);

  // Keys with an Android hardware button behind them.
  static const contextMenu = DesktopKey(0x00100000505);
  static const browserSearch = DesktopKey(0x00100000c06);
  static const goBack = DesktopKey(0x00100001005);
  static const audioVolumeUp = DesktopKey(0x00100000a10);
  static const audioVolumeDown = DesktopKey(0x00100000a0f);

  // Punctuation, reached only under a modifier.
  static const minus = DesktopKey(0x0000000002d);
  static const equal = DesktopKey(0x0000000003d);
  static const bracketLeft = DesktopKey(0x0000000005b);
  static const bracketRight = DesktopKey(0x0000000005d);
  static const backslash = DesktopKey(0x0000000005c);
  static const semicolon = DesktopKey(0x0000000003b);
  static const quote = DesktopKey(0x00000000022);
  static const backquote = DesktopKey(0x00000000060);
  static const comma = DesktopKey(0x0000000002c);
  static const period = DesktopKey(0x0000000002e);
  static const slash = DesktopKey(0x0000000002f);

  static const f1 = DesktopKey(0x00100000801);
  static const f2 = DesktopKey(0x00100000802);
  static const f3 = DesktopKey(0x00100000803);
  static const f4 = DesktopKey(0x00100000804);
  static const f5 = DesktopKey(0x00100000805);
  static const f6 = DesktopKey(0x00100000806);
  static const f7 = DesktopKey(0x00100000807);
  static const f8 = DesktopKey(0x00100000808);
  static const f9 = DesktopKey(0x00100000809);
  static const f10 = DesktopKey(0x0010000080a);
  static const f11 = DesktopKey(0x0010000080b);
  static const f12 = DesktopKey(0x0010000080c);

  /// The trigger of [kDeviceKeyboardEscape]. A `const` chord needs a `const`
  /// key, and [printable] is a function.
  static const keyK = DesktopKey(0x0000000006b);

  /// The key that produces [character] unmodified. A printable key's id *is* its
  /// lower-case code point, so letters and digits need no table.
  static DesktopKey printable(String character) =>
      DesktopKey(character.toLowerCase().codeUnitAt(0));

  static const Map<int, String> _labels = {
    0x002000001f0: 'Control',
    0x00200000100: 'Control Left',
    0x00200000101: 'Control Right',
    0x002000001f2: 'Shift',
    0x00200000102: 'Shift Left',
    0x00200000103: 'Shift Right',
    0x002000001f4: 'Alt',
    0x00200000104: 'Alt Left',
    0x00200000105: 'Alt Right',
    0x002000001f6: 'Meta',
    0x00200000106: 'Meta Left',
    0x00200000107: 'Meta Right',
    0x00100000106: 'Fn',
    0x00100000008: 'Backspace',
    0x0010000007f: 'Delete',
    0x0010000000d: 'Enter',
    0x0020000020d: 'Numpad Enter',
    0x00100000009: 'Tab',
    0x0010000001b: 'Escape',
    0x00100000407: 'Insert',
    0x00100000104: 'Caps Lock',
    0x00100000304: 'Arrow Up',
    0x00100000301: 'Arrow Down',
    0x00100000302: 'Arrow Left',
    0x00100000303: 'Arrow Right',
    0x00100000306: 'Home',
    0x00100000305: 'End',
    0x00100000308: 'Page Up',
    0x00100000307: 'Page Down',
    0x00100000505: 'Context Menu',
    0x00100000c06: 'Browser Search',
    0x00100001005: 'Go Back',
    0x00100000a10: 'Audio Volume Up',
    0x00100000a0f: 'Audio Volume Down',
    0x00100000801: 'F1',
    0x00100000802: 'F2',
    0x00100000803: 'F3',
    0x00100000804: 'F4',
    0x00100000805: 'F5',
    0x00100000806: 'F6',
    0x00100000807: 'F7',
    0x00100000808: 'F8',
    0x00100000809: 'F9',
    0x0010000080a: 'F10',
    0x0010000080b: 'F11',
    0x0010000080c: 'F12',
  };
}

/// The key's position, Flutter's `DesktopPhysicalKey.usbHidUsage`. What is held
/// is tracked by position: the logical key can change under a modifier.
extension type const DesktopPhysicalKey(int usbHidUsage) {}

/// Which edge of a key press this is.
enum DesktopKeyEventKind { down, up, repeat }

/// One desktop key event, as Flutter's `KeyEvent` hierarchy reports it. A value,
/// so building one in a test is a constructor call instead of a binding.
class DesktopKeyEvent {
  const DesktopKeyEvent({
    required this.kind,
    required this.physicalKey,
    required this.logicalKey,
    this.character,
  });

  final DesktopKeyEventKind kind;
  final DesktopPhysicalKey physicalKey;
  final DesktopKey logicalKey;

  /// What the desktop's layout says this keystroke types, or `null` for a key
  /// that types nothing.
  final String? character;

  @override
  String toString() =>
      'DesktopKeyEvent(${kind.name}, $logicalKey'
      '${character == null ? '' : ', "$character"'})';
}

/// Android `KeyEvent.ACTION_*`.
abstract final class AndroidKeyAction {
  static const int down = 0;
  static const int up = 1;
}

/// Android `KeyEvent.META_*`. Only the generic bits are sent: `isCtrlPressed()`
/// and its siblings test exactly these, not the left/right ones.
abstract final class AndroidMetaState {
  static const int none = 0;
  static const int shiftOn = 0x1;
  static const int altOn = 0x2;
  static const int ctrlOn = 0x1000;
  static const int metaOn = 0x10000;
  static const int capsLockOn = 0x100000;
  static const int numLockOn = 0x200000;
}

/// The AOSP `KEYCODE_*` values this app can send. Numbers rather than names
/// because both transports take numbers.
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

/// Modifiers held on the desktop when a key event arrived. A value, so the
/// translation is a pure function a test can drive without a binding.
class DesktopModifiers {
  const DesktopModifiers({
    this.shift = false,
    this.control = false,
    this.alt = false,
    this.meta = false,
    this.capsLock = false,
    this.numLock = false,
  });

  final bool shift;
  final bool control;
  final bool alt;
  final bool meta;
  final bool capsLock;
  final bool numLock;

  /// Whether a modifier is held that changes what a *character* key means. Not
  /// shift: it has already produced the character Flutter reported.
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
  /// can still say which key was pressed. Null reads as "no equivalent".
  final DesktopKey? logicalKey;

  /// Whether this needs a modifier the transport may not be able to carry. Shift
  /// does not count: the printable path has already applied it.
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

/// A modifier + key combination, described without the widget layer's
/// `SingleActivator` — this is the domain.
class DeviceKeyChord {
  const DeviceKeyChord({
    required this.trigger,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });

  final DesktopKey trigger;
  final bool control;
  final bool alt;
  final bool shift;
}

/// The chord that turns forwarding on and off, and the one chord never sent to
/// the device: with forwarding on the pane swallows every other way back out.
const DeviceKeyChord kDeviceKeyboardEscape = DeviceKeyChord(
  trigger: DesktopKey.keyK,
  control: true,
  alt: true,
);

/// [kDeviceKeyboardEscape] as the user should read it. Written wherever the
/// forwarding state is shown, because a hidden escape hatch is not one.
const String kDeviceKeyboardEscapeLabel = 'Ctrl+Alt+K';

/// Keys that are only ever a modifier; Android carries their state on every
/// other event, so forwarding them alone does nothing.
// `final`, not `const`: `DesktopKey` overrides `==`, and Dart refuses
// such a value as a key in a constant collection.
final Set<DesktopKey> _modifierKeys = {
  DesktopKey.control,
  DesktopKey.controlLeft,
  DesktopKey.controlRight,
  DesktopKey.shift,
  DesktopKey.shiftLeft,
  DesktopKey.shiftRight,
  DesktopKey.alt,
  DesktopKey.altLeft,
  DesktopKey.altRight,
  DesktopKey.meta,
  DesktopKey.metaLeft,
  DesktopKey.metaRight,
  DesktopKey.fn,
};

/// Desktop keys with a fixed Android keycode.
final Map<DesktopKey, int> _keyCodes = {
  DesktopKey.backspace: AndroidKeyCode.del,
  DesktopKey.delete: AndroidKeyCode.forwardDel,
  DesktopKey.enter: AndroidKeyCode.enter,
  DesktopKey.numpadEnter: AndroidKeyCode.enter,
  DesktopKey.tab: AndroidKeyCode.tab,
  DesktopKey.escape: AndroidKeyCode.escape,
  DesktopKey.space: AndroidKeyCode.space,
  DesktopKey.insert: AndroidKeyCode.insert,
  DesktopKey.capsLock: AndroidKeyCode.capsLock,
  DesktopKey.arrowUp: AndroidKeyCode.dpadUp,
  DesktopKey.arrowDown: AndroidKeyCode.dpadDown,
  DesktopKey.arrowLeft: AndroidKeyCode.dpadLeft,
  DesktopKey.arrowRight: AndroidKeyCode.dpadRight,
  DesktopKey.home: AndroidKeyCode.moveHome,
  DesktopKey.end: AndroidKeyCode.moveEnd,
  DesktopKey.pageUp: AndroidKeyCode.pageUp,
  DesktopKey.pageDown: AndroidKeyCode.pageDown,
  DesktopKey.contextMenu: AndroidKeyCode.menu,
  DesktopKey.browserSearch: AndroidKeyCode.search,
  DesktopKey.goBack: AndroidKeyCode.back,
  DesktopKey.audioVolumeUp: AndroidKeyCode.volumeUp,
  DesktopKey.audioVolumeDown: AndroidKeyCode.volumeDown,
  // Punctuation, reached only under a modifier — Ctrl+- and Ctrl+= are zoom in
  // a browser on the phone as much as they are here.
  DesktopKey.minus: 69,
  DesktopKey.equal: 70,
  DesktopKey.bracketLeft: 71,
  DesktopKey.bracketRight: 72,
  DesktopKey.backslash: 73,
  DesktopKey.semicolon: 74,
  DesktopKey.quote: 75,
  DesktopKey.backquote: 68,
  DesktopKey.comma: 55,
  DesktopKey.period: 56,
  DesktopKey.slash: 76,
};

/// The twelve function keys, which are contiguous on both sides.
final Map<DesktopKey, int> _functionKeys = {
  DesktopKey.f1: 131,
  DesktopKey.f2: 132,
  DesktopKey.f3: 133,
  DesktopKey.f4: 134,
  DesktopKey.f5: 135,
  DesktopKey.f6: 136,
  DesktopKey.f7: 137,
  DesktopKey.f8: 138,
  DesktopKey.f9: 139,
  DesktopKey.f10: 140,
  DesktopKey.f11: 141,
  DesktopKey.f12: 142,
};

/// The Android keycode for [key], or `null` if there is not one.
int? androidKeyCodeFor(DesktopKey key) {
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

/// Desktop keys that exist on an iOS keyboard too. The gaps are the point:
/// Android hardware keys have no iOS equivalent, and a gap is refused out loud.
final Map<DesktopKey, SimulatorKey> _simulatorKeys = {
  DesktopKey.backspace: SimulatorKey.backspace,
  DesktopKey.delete: SimulatorKey.forwardDelete,
  DesktopKey.enter: SimulatorKey.returnKey,
  DesktopKey.numpadEnter: SimulatorKey.returnKey,
  DesktopKey.tab: SimulatorKey.tab,
  DesktopKey.escape: SimulatorKey.escape,
  DesktopKey.insert: SimulatorKey.insert,
  DesktopKey.capsLock: SimulatorKey.capsLock,
  DesktopKey.arrowUp: SimulatorKey.arrowUp,
  DesktopKey.arrowDown: SimulatorKey.arrowDown,
  DesktopKey.arrowLeft: SimulatorKey.arrowLeft,
  DesktopKey.arrowRight: SimulatorKey.arrowRight,
  DesktopKey.home: SimulatorKey.home,
  DesktopKey.end: SimulatorKey.end,
  DesktopKey.pageUp: SimulatorKey.pageUp,
  DesktopKey.pageDown: SimulatorKey.pageDown,
  DesktopKey.f1: SimulatorKey.f1,
  DesktopKey.f2: SimulatorKey.f2,
  DesktopKey.f3: SimulatorKey.f3,
  DesktopKey.f4: SimulatorKey.f4,
  DesktopKey.f5: SimulatorKey.f5,
  DesktopKey.f6: SimulatorKey.f6,
  DesktopKey.f7: SimulatorKey.f7,
  DesktopKey.f8: SimulatorKey.f8,
  DesktopKey.f9: SimulatorKey.f9,
  DesktopKey.f10: SimulatorKey.f10,
  DesktopKey.f11: SimulatorKey.f11,
  DesktopKey.f12: SimulatorKey.f12,
};

/// The iOS key for [key], or `null` if iOS has no such key. No letter or digit
/// fallback: this transport cannot send a chord, so a letter is just a letter.
SimulatorKey? simulatorKeyFor(DesktopKey key) => _simulatorKeys[key];

/// Translates one desktop keyboard into one Android keyboard. Stateful: a key
/// sent as text must send no `ACTION_UP`, and a held key must be lifted.
class DeviceKeyTranslator {
  /// Physical keys currently down *as a keycode*, and their repeat counters. The
  /// logical key is kept beside it so [releaseAll] can build a complete intent.
  final Map<
    DesktopPhysicalKey,
    ({int keyCode, int repeat, DesktopKey logicalKey})
  >
  _down = {};

  /// The event's Android form, or `null` when nothing should be sent.
  DeviceKeyIntent? translate(DesktopKeyEvent event, DesktopModifiers modifiers) {
    // Reserved before anything else: this is the way back out, and it must not
    // be reachable by any path that could send it to the device.
    if (isEscapeChord(event, modifiers)) return null;

    if (_modifierKeys.contains(event.logicalKey)) return null;

    if (event.kind == DesktopKeyEventKind.up) {
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
    final repeat =
        event.kind == DesktopKeyEventKind.repeat ? (previous?.repeat ?? 0) + 1 : 0;
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

  /// Whether [event] is [kDeviceKeyboardEscape], down or up. Both halves, or the
  /// release of a swallowed press goes out as an unpaired `ACTION_UP`.
  static bool isEscapeChord(DesktopKeyEvent event, DesktopModifiers modifiers) =>
      event.logicalKey == kDeviceKeyboardEscape.trigger &&
      modifiers.control &&
      modifiers.alt &&
      !modifiers.meta;

  /// A character Flutter reports for a key that is not really text — `\n` for
  /// Enter. A search field submits on Enter and ignores a typed newline.
  static bool _isControlCharacter(String character) {
    final unit = character.codeUnitAt(0);
    return unit < 0x20 || unit == 0x7F;
  }
}
