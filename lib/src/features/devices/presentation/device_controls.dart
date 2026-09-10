import 'dart:io';

import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';

/// One button on a [DeviceControlBar].
class DeviceControl {
  const DeviceControl({
    required this.name,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.buttonKey,
  });

  /// What this control is called when it fails: "Screenshot failed: …". Not
  /// the [tooltip], which names the *next* action and reads wrong in one.
  final String name;

  final String tooltip;
  final IconData icon;

  /// `null` disables the button rather than removing it: one that vanishes
  /// reads as a fault in the app, while an inert one says what is missing.
  final Future<void> Function()? onPressed;

  final Key? buttonKey;
}

/// The row of controls under a live picture, on either platform. Shared for
/// the manners — one action at a time, failures out loud — not the buttons.
class DeviceControlBar extends StatefulWidget {
  const DeviceControlBar({super.key, required this.controls});

  final List<DeviceControl> controls;

  @override
  State<DeviceControlBar> createState() => _DeviceControlBarState();
}

class _DeviceControlBarState extends State<DeviceControlBar> {
  bool _busy = false;

  Future<void> _run(DeviceControl control) async {
    final action = control.onPressed;
    if (_busy || action == null) return;
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      // Named, and out loud: these reach the device through a process that
      // can fail for reasons the user can act on; silence reads as a no-op.
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('${control.name} failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      // A [Wrap], not a [Row]: the pane's width and the platform's control
      // count are unrelated, and one more button overflowed a compact pane.
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          for (final control in widget.controls)
            IconButton(
              key: control.buttonKey,
              tooltip: control.tooltip,
              icon: Icon(control.icon),
              onPressed: _busy || control.onPressed == null
                  ? null
                  : () => _run(control),
            ),
        ],
      ),
    );
  }
}

/// Where a screenshot goes, or `null` on a host with no home directory. The
/// Desktop, and shared so Android and iOS cannot drift into two folders.
String? desktopScreenshotPath(String what) {
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
  return '$home/Desktop/$what Screen Shot $stamp.png';
}

/// Asks for a URL to open on the device, with **no `TextEditingController`**:
/// one disposed when `showDialog` returns throws through the exit animation.
Future<String?> askForDeviceUrl(BuildContext context) {
  var typed = '';
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open a URL'),
      content: TextField(
        key: const Key('device-url-field'),
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'myapp://path, or https://example.com',
        ),
        onChanged: (value) => typed = value,
        onSubmitted: Navigator.of(context).pop,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('device-url-open'),
          onPressed: () => Navigator.of(context).pop(typed),
          child: const Text('Open'),
        ),
      ],
    ),
  );
}
