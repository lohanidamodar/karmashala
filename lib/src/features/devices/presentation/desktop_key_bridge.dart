import 'package:flutter/services.dart';
import 'package:karmashala_devices/devices.dart';

/// Flutter's keyboard, said in the words `karmashala_devices` understands.
///
/// The package translates a desktop keystroke into an Android key event or a
/// WebDriverAgent one, and none of that arithmetic needs a widget — so it holds
/// the key as a value (`DesktopKey` is Flutter's `keyId`, `DesktopPhysicalKey`
/// its `usbHidUsage`) and runs under plain `dart test`. Flutter's own types
/// only ever reach this file, which is the boundary the package was shaped for:
/// the ids are byte-for-byte the same, so each conversion is one expression.
extension DesktopKeyEventBridge on KeyEvent {
  DesktopKeyEvent get asDesktopKeyEvent => DesktopKeyEvent(
    kind: switch (this) {
      KeyDownEvent() => DesktopKeyEventKind.down,
      KeyRepeatEvent() => DesktopKeyEventKind.repeat,
      _ => DesktopKeyEventKind.up,
    },
    physicalKey: DesktopPhysicalKey(physicalKey.usbHidUsage),
    logicalKey: DesktopKey(logicalKey.keyId),
    character: character,
  );
}

/// The modifiers held right now, according to Flutter.
///
/// This was `DesktopModifiers.live()`, and it is the one part of the keyboard
/// layer that could not travel: it reads `HardwareKeyboard`, which is a
/// binding. The value it returns is the package's, so the translation stays a
/// pure function a test drives without one.
DesktopModifiers liveDesktopModifiers() {
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
