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

  /// What this control is called when it fails: "Screenshot failed: …".
  ///
  /// Separate from [tooltip] because the tooltip names the *next* action —
  /// "Switch to dark appearance" — and a failure message built from that reads
  /// as a sentence about something that was never going to happen.
  final String name;

  final String tooltip;
  final IconData icon;

  /// `null` disables the button rather than removing it.
  ///
  /// Deliberately still drawn: a control that vanishes when the device goes
  /// reads as a fault in the app, while an inert one with a tooltip says what
  /// is missing. The tooltip is what has to carry the explanation.
  final Future<void> Function()? onPressed;

  final Key? buttonKey;
}

/// The row of controls under a live picture, on either platform.
///
/// Shared between the iOS and Android panes because the *behaviour* is shared,
/// not because the two rows look alike. Every control here spawns a process and
/// takes a moment to answer, and all of them want the same three things: one
/// action in flight at a time, a failure that is said out loud rather than
/// swallowed, and no press accepted while the last one is still running. That
/// used to live in the simulator pane alone, so the Android row — which had
/// only key presses, none of which can fail visibly — silently grew a different
/// set of manners as soon as it gained a screenshot.
///
/// The controls themselves stay with their platform. What Android and iOS can
/// do genuinely differs (there is no Recents on iPhone; adb cannot unlock a
/// secured device), and a widget that tried to own both lists would have to
/// carry a platform switch for every button.
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
      // Named, and out loud. These all reach the device through a process that
      // can fail for reasons the user can act on — a simulator that went away,
      // a deep link nothing is registered for — and a caught-and-dropped
      // failure here is indistinguishable from the device ignoring the tap.
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
      // A [Wrap], not a [Row]. The row is as wide as the controls its platform
      // has, the pane is as wide as the user made the side panel, and the two
      // are unrelated — adding a Record button overflowed a compact pane by 42
      // pixels. Wrapping keeps every control reachable at every width instead
      // of clipping the last ones.
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

/// Where a screenshot goes, or `null` on a host with no home directory.
///
/// The Desktop, because that is where the Simulator's own Cmd+S puts them and
/// it is the one place a person will think to look. Shared so the Android and
/// iOS controls cannot drift into saving to two different folders under two
/// different names — [what] is the only part that differs, and it is there so
/// the file says which kind of device it came from.
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

/// Asks for a URL to open on the device. Null if the dialog was dismissed.
///
/// Extracted so it can be tested on its own — it is the whole of a bug worth a
/// regression test. It holds **no `TextEditingController`**: the first version
/// created one and disposed it as soon as `showDialog` returned, which is after
/// the route pops but *before* its exit animation has finished painting the
/// field. Every frame of that animation then threw "A TextEditingController was
/// used after being disposed", and because the error repeats per frame it took
/// the whole app into an error state rather than failing once.
///
/// Reading the text from `onChanged` needs no controller and so cannot outlive
/// one.
///
/// Device-shaped rather than simulator-shaped: `simctl openurl` and
/// `am start -a android.intent.action.VIEW` take the same thing from the user
/// and mean the same thing by it, so there is one dialog and one set of keys
/// for both.
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
