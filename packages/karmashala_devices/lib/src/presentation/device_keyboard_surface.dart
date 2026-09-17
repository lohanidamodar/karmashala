import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../devices.dart';

import 'desktop_key_bridge.dart';
import 'device_list_row.dart';

/// What the bar says the keyboard is doing. Public so a test asserts the same
/// words the user reads.
const String kKeyboardOnLabel = 'Typing goes to the device';
const String kKeyboardOffLabel = 'Typing stays in Karmashala';
const String kKeyboardUnavailableLabel = 'Keyboard forwarding unavailable';

/// The keyboard target laid over the live view, and the line under it. Focus
/// is the switch; [kDeviceKeyboardEscape] is reserved as the way back out.
class DeviceKeyboardSurface extends StatefulWidget {
  const DeviceKeyboardSurface({
    super.key,
    required this.child,
    this.sink,
    this.deviceLabel,
  });

  /// Where keystrokes go. `null` means no transport is available, and nothing
  /// can be forwarded at all.
  final DeviceKeyboardSink? sink;

  /// The device being typed into, named in the bar. A picture of a phone is
  /// anonymous, and "your keyboard now drives *that*" needs a subject.
  final String? deviceLabel;

  final Widget child;

  @override
  State<DeviceKeyboardSurface> createState() => _DeviceKeyboardSurfaceState();
}

class _DeviceKeyboardSurfaceState extends State<DeviceKeyboardSurface> {
  final FocusNode _node = FocusNode(debugLabel: 'device-keyboard');
  final DeviceKeyTranslator _translator = DeviceKeyTranslator();
  bool _hasFocus = false;

  /// Whether the user has explicitly told this pane to stop. Not cleared on
  /// focus loss: turning it off, clicking away and back is not asking again.
  bool _suspended = false;

  /// The last thing that could not be sent, shown in the bar. A keystroke that
  /// goes nowhere must not go nowhere *quietly*.
  String? _notice;

  /// Whether keystrokes would be forwarded if this pane had focus.
  bool get _armed => widget.sink != null && !_suspended;

  /// Whether keystrokes are being forwarded *right now*.
  bool get _live => _armed && _hasFocus;

  @override
  void dispose() {
    _releaseHeldKeys();
    _node.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DeviceKeyboardSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sink != widget.sink) {
      // The transport changed under us, so what the old one believed was held
      // is not ours to lift through the new one — reset, never replayed.
      _releaseHeldKeys();
      _notice = null;
    }
  }

  /// Lifts every key the device still believes is down.
  void _releaseHeldKeys() {
    final sink = widget.sink;
    for (final intent in _translator.releaseAll()) {
      sink?.send(intent);
    }
  }

  void _onFocusChange(bool hasFocus) {
    // Losing focus stops forwarding, so anything held has to be lifted, or an
    // arrow key left down scrolls a list to the bottom on its own.
    if (!hasFocus) _releaseHeldKeys();
    setState(() {
      _hasFocus = hasFocus;
      if (!hasFocus) _notice = null;
    });
  }

  void _setSuspended(bool value) {
    if (widget.sink == null) return;
    if (value) _releaseHeldKeys();
    setState(() {
      _suspended = value;
      _notice = null;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final modifiers = liveDesktopModifiers();
    final desktopEvent = event.asDesktopKeyEvent;

    // First, always, and from either state: this is the way back out, and it
    // must never be reachable by a path that could send it to the device.
    if (DeviceKeyTranslator.isEscapeChord(desktopEvent, modifiers)) {
      if (event is KeyDownEvent && widget.sink != null) {
        _setSuspended(!_suspended);
      }
      // The release is swallowed too, so the app never sees half a chord.
      return KeyEventResult.handled;
    }

    final sink = widget.sink;
    if (!_armed || sink == null) {
      // Suspended, or nothing to send through. Not consumed: a key not going
      // to the device should go back to Karmashala rather than nowhere.
      return KeyEventResult.ignored;
    }

    final intent = _translator.translate(desktopEvent, modifiers);
    if (intent == null) {
      // Nothing to send — a lone modifier, or a key with no equivalent. Still
      // consumed: while armed, the app's shortcuts must not fire behind you.
      return KeyEventResult.handled;
    }
    if (!sink.send(intent)) {
      // The sink's own reason first: it knows which key was refused, where
      // the transport's [limitation] is one blanket sentence.
      final reason = sink.refusal ?? sink.transport.limitation;
      setState(
        () => _notice = reason ?? 'That key could not be sent to the device.',
      );
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget picture = Focus(
      focusNode: _node,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKey,
      child: Listener(
        // A raw listener, not a tap recogniser: the touch surface below is
        // one too, and two would compete in the gesture arena for every tap.
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _node.requestFocus(),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: _live ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
    if (_armed) {
      // Only while armed: a mirror that is not forwarding has no claim on the
      // keyboard, and marking it would pin focus away from the terminal.
      picture = KeyboardCaptureScope(child: picture);
    }

    return Column(
      children: [
        Expanded(child: picture),
        _KeyboardBar(
          armed: _armed,
          focused: _hasFocus,
          available: widget.sink != null,
          transport: widget.sink?.transport,
          deviceLabel: widget.deviceLabel,
          notice: _notice,
          onChanged: widget.sink == null
              ? null
              : (value) => _setSuspended(!value),
        ),
      ],
    );
  }
}

/// The line under the picture that says, in words, where the keyboard goes.
class _KeyboardBar extends StatelessWidget {
  const _KeyboardBar({
    required this.armed,
    required this.focused,
    required this.available,
    required this.transport,
    required this.deviceLabel,
    required this.notice,
    required this.onChanged,
  });

  final bool armed;
  final bool focused;
  final bool available;
  final DeviceKeyboardTransport? transport;
  final String? deviceLabel;
  final String? notice;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = deviceLabel ?? 'the device';
    // The headline is where keys are going *now*, not what is configured:
    // armed but unfocused is not typing into the device.
    final live = armed && focused;
    final (label, icon) = switch ((available, live)) {
      (false, _) => (kKeyboardUnavailableLabel, AppIcons.warningCircle),
      // The keyboard both ways: the headline and the accent say which.
      (true, true) => (kKeyboardOnLabel, AppIcons.keyboard),
      (true, false) => (kKeyboardOffLabel, AppIcons.keyboard),
    };
    // What the transport cannot do is said while it is armed, focused or not:
    // finding out that Ctrl+C went nowhere by pressing it is not a report.
    final limits = transport?.limitation == null
        ? ''
        : '${transport!.limitation}. ';
    final detail = switch ((available, armed, focused)) {
      // Says *what* is missing without naming a transport: this bar sits
      // under an Android mirror and an iOS simulator alike.
      (false, _, _) =>
        'Nothing here can carry a keystroke to this device, so it cannot be '
            'typed into.',
      (true, false, _) =>
        'Forwarding is off. Turn it back on here, or with '
            '$kDeviceKeyboardEscapeLabel, and your keyboard drives $device '
            'whenever this pane is focused.',
      (true, true, false) =>
        '${limits}Click the picture and your keyboard drives $device — a '
            'background mirror is never typed into.',
      (true, true, true) =>
        '$limits'
            "Karmashala's own shortcuts now go to $device. "
            '$kDeviceKeyboardEscapeLabel to stop.',
    };
    final colour = live ? theme.colorScheme.primary : theme.colorScheme.outline;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.xs,
      ),
      child: Row(
        children: [
          Icon(icon, size: Chrome.iconSmall, color: colour),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: colour),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  notice ?? detail,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: notice == null
                        ? theme.colorScheme.outline
                        : theme.colorScheme.error,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          Semantics(
            label: 'Send keyboard to $device',
            // The pane's one switch, ending on the pane's one right edge.
            child: DeviceSwitch(value: armed, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}
