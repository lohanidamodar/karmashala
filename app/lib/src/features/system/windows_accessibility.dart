import 'dart:io';

import 'package:flutter/services.dart';
import 'package:karmashala_core/logging.dart';

/// The Windows runner's switch for answering accessibility clients.
const kWindowsAccessibilityChannel = MethodChannel(
  'karmashala/windows_accessibility',
);

final _log = AppLogger.named('a11y');

/// **Screen reader support on Windows**, held off unless the setting is on.
///
/// The runner answers no accessibility client — a screen reader, the touch
/// keyboard, anything asking through UI Automation — until it is told it may:
/// while one reads the app, the Flutter engine's Windows accessibility bridge
/// can erase a child id its parent no longer lists, and the copy that follows
/// runs off the end of the buffer (crash dumps of 2026-10-09, -14 and -15:
/// `AccessibilityBridge::CreateRemoveReparentedNodesUpdate`, then heap
/// corruption). Allowing it takes effect at once; taking it back, at the
/// next launch, since the engine keeps semantics on once they started.
class WindowsAccessibilityGuard {
  WindowsAccessibilityGuard({bool? onWindows})
    : _onWindows = onWindows ?? Platform.isWindows;

  final bool _onWindows;
  bool? _told;

  /// Tells the runner whether accessibility clients are [allowed], when that
  /// changed since it last heard.
  Future<void> apply({required bool allowed}) async {
    if (!_onWindows || _told == allowed) return;
    try {
      await kWindowsAccessibilityChannel.invokeMethod<void>(
        'setAllowed',
        allowed,
      );
      _told = allowed;
    } on MissingPluginException {
      // A runner from before the switch: it answers every client, as before.
    } on PlatformException catch (error) {
      _log.warning('Screen reader support not applied: ${error.message}');
    }
  }
}
