import 'package:flutter/services.dart';
import 'package:karmashala_devices/devices.dart';

/// Flutter's keyboard, said in the words `karmashala_devices` understands.
/// Flutter's types stop here, so the translation runs under plain `dart test`.
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

/// The modifiers held right now, according to Flutter. The one part of the
/// keyboard layer that could not travel: it reads `HardwareKeyboard`.
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
