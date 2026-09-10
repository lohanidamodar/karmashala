import 'package:flutter/foundation.dart';

import 'package:karmashala_ui/icons.dart';
import '../application/device_clipboard_bridge.dart';
import 'device_controls.dart';

/// The two clipboard buttons on a device's control row. Gated on the control
/// socket, not adb — off in the one case where the rest of the row works.
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

/// What a clipboard button says, including why it is off: a disabled button
/// with no reason reads as a fault in the app.
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

