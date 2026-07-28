import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// The built-in default launcher hotkey: Ctrl+Alt+Space — non-conflicting on
/// Windows and easy to reach one-handed.
HotKey defaultLauncherHotKey() => HotKey(
  key: LogicalKeyboardKey.space,
  modifiers: const [HotKeyModifier.control, HotKeyModifier.alt],
  scope: HotKeyScope.system,
);

/// Serializes [hotKey] to a string for persistence in settings.
String encodeLauncherHotKey(HotKey hotKey) => jsonEncode(hotKey.toJson());

/// Rebuilds a [HotKey] from persisted [json], or the default when [json] is
/// null or unparseable. The scope is always forced to system so a corrupt or
/// legacy value can't accidentally register as in-app only.
HotKey decodeLauncherHotKey(String? json) {
  if (json == null) return defaultLauncherHotKey();
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) return defaultLauncherHotKey();
    final hotKey = HotKey.fromJson(decoded);
    return HotKey(
      key: hotKey.key,
      modifiers: hotKey.modifiers,
      scope: HotKeyScope.system,
    );
  } catch (_) {
    return defaultLauncherHotKey();
  }
}

/// A human-readable label such as "Ctrl + Alt + Space".
String launcherHotKeyLabel(HotKey hotKey) {
  const order = [
    HotKeyModifier.control,
    HotKeyModifier.alt,
    HotKeyModifier.shift,
    HotKeyModifier.meta,
  ];
  const names = {
    HotKeyModifier.control: 'Ctrl',
    HotKeyModifier.alt: 'Alt',
    HotKeyModifier.shift: 'Shift',
    HotKeyModifier.meta: 'Meta',
  };
  final parts = <String>[
    for (final m in order)
      if (hotKey.modifiers?.contains(m) ?? false) names[m]!,
    _keyLabel(hotKey.logicalKey),
  ];
  return parts.join(' + ');
}

String _keyLabel(LogicalKeyboardKey key) {
  final label = key.keyLabel.trim();
  if (label.isNotEmpty) return label;
  return key.debugName ?? 'Key';
}
