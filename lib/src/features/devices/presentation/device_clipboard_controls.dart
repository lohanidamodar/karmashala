import 'package:flutter/foundation.dart';

import '../../../app/theme/app_icons.dart';
import '../application/device_clipboard_bridge.dart';
import 'device_controls.dart';

/// The two clipboard buttons on a device's control row.
///
/// Its own function rather than inline in the pane so the *decisions* can be
/// tested without a live view: which button is off, what it says when it is,
/// and — the one that matters — what the user is told when the device would
/// not answer. A `null` [bridge] is not a capability flag but the absence of a
/// transport, and it is the case with the most to explain.
///
/// **Gated on the control socket, not on adb.** Every other control on that row
/// works over `adb shell`; the clipboard cannot, because adb has no clipboard
/// verb — see `DeviceClipboardBridge` for the measurements. So these two are
/// off in exactly the situation where the rest of the row still works, which is
/// confusing enough to deserve a sentence rather than a greyed-out icon.
List<DeviceControl> deviceClipboardControls({
  required DeviceClipboardBridge? bridge,
  required void Function(String message) say,
}) => [
  DeviceControl(
    name: 'Copy to device',
    tooltip: _tooltip(bridge, "Copy this computer's clipboard to the device"),
    // Up onto the device, down to this computer — the same sense the files
    // dialog uses, where `downloadSimple` means "save here".
    icon: AppIcons.arrowUp,
    onPressed: bridge == null ? null : () => _toDevice(bridge, say),
    buttonKey: const ValueKey('android-clipboard-to-device'),
  ),
  DeviceControl(
    name: 'Copy from device',
    tooltip: _tooltip(bridge, "Copy the device's clipboard to this computer"),
    icon: AppIcons.arrowDown,
    onPressed: bridge == null ? null : () => _fromDevice(bridge, say),
    buttonKey: const ValueKey('android-clipboard-from-device'),
  ),
];

/// What a clipboard button says, including why it is off.
///
/// A disabled button with no reason reads as a fault in the app.
String _tooltip(DeviceClipboardBridge? bridge, String enabled) {
  if (bridge == null) {
    return 'The clipboard travels over the live view\'s control socket, and '
        'this device has none. Start the live view; if it is already on, input '
        'has fallen back to adb, which has no clipboard verb at all.';
  }
  return bridge.refusal ?? enabled;
}

Future<void> _toDevice(
  DeviceClipboardBridge bridge,
  void Function(String) say,
) async {
  final write = await bridge.copyHostToDevice();
  // The detail, never the text. Clipboard contents are user data, and a
  // SnackBar is a place they would be read over somebody's shoulder.
  say(write.detail);
}

Future<void> _fromDevice(
  DeviceClipboardBridge bridge,
  void Function(String) say,
) async {
  // The device pushes its clipboard whenever it changes, so the usual case
  // needs no round trip at all. Asking is the fallback, not the default.
  final read = bridge.latest.hasText
      ? await bridge.copyLatestToHost()
      : await bridge.copyDeviceToHost();
  say(
    read.hasText ? 'Copied to this computer — ${read.summary}.' : read.summary,
  );
}

