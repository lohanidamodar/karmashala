import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../data/device_keyboard_sink.dart';
import '../domain/device_keyboard.dart';

/// What the bar says the keyboard is doing. Public so a test asserts the same
/// words the user reads.
const String kKeyboardOnLabel = 'Typing goes to the device';
const String kKeyboardOffLabel = 'Typing stays in Karmashala';
const String kKeyboardUnavailableLabel = 'Keyboard forwarding unavailable';

/// The keyboard target laid over the live view, and the switch that arms it.
///
/// The owner asked for this: "can we send keyboard events in live when actively
/// focused there? with a option to stop sending keyboard?" Both halves matter,
/// and the second is the one that makes the first safe to use.
///
/// **Armed, this pane eats the app's shortcuts.** That is the feature — Ctrl+W
/// has to close a tab on the phone rather than in Karmashala — and it is also
/// the hazard, because it leaves the user holding a keyboard that no longer
/// talks to the app. So:
///
/// * it defaults to **off**, and is armed only by an explicit act;
/// * it forwards only while this pane actually **has focus**, so a mirror in a
///   background pane never sees a keystroke;
/// * [kDeviceKeyboardEscape] is reserved — never translated, never sent —
///   and toggles the switch from either state, so there is always a way back;
/// * the current state is written on screen in words, not signalled by colour.
class DeviceKeyboardSurface extends StatefulWidget {
  const DeviceKeyboardSurface({
    super.key,
    required this.child,
    required this.forwarding,
    required this.onForwardingChanged,
    this.sink,
    this.deviceLabel,
  });

  /// Where keystrokes go. `null` means neither transport is available, and the
  /// switch cannot be armed at all.
  final DeviceKeyboardSink? sink;

  /// Whether keystrokes are being forwarded. Owned by the pane, so stopping the
  /// live view can disarm it.
  final bool forwarding;

  final ValueChanged<bool> onForwardingChanged;

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

  /// The last thing that could not be sent, shown in the bar. A keystroke that
  /// goes nowhere must not go nowhere *quietly*.
  String? _notice;

  @override
  void dispose() {
    _releaseHeldKeys();
    _node.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DeviceKeyboardSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.forwarding && !widget.forwarding) {
      // Disarming with a key held would leave the device holding it forever.
      _releaseHeldKeys();
      _notice = null;
    }
    if (oldWidget.sink != widget.sink) _notice = null;
  }

  /// Lifts every key the device still believes is down.
  void _releaseHeldKeys() {
    final sink = widget.sink;
    for (final intent in _translator.releaseAll()) {
      sink?.send(intent);
    }
  }

  void _onFocusChange(bool hasFocus) {
    if (!hasFocus) _releaseHeldKeys();
    setState(() => _hasFocus = hasFocus);
  }

  void _toggle(bool value) {
    if (widget.sink == null) return;
    widget.onForwardingChanged(value);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final modifiers = DesktopModifiers.live();

    // First, always, and from either state: this is the way back out, and it
    // must never be reachable by a path that could send it to the device.
    if (DeviceKeyTranslator.isEscapeChord(event, modifiers)) {
      if (event is KeyDownEvent) _toggle(!widget.forwarding);
      // The release is swallowed too, so the app never sees half a chord.
      return KeyEventResult.handled;
    }

    final sink = widget.sink;
    if (!widget.forwarding || sink == null) {
      // Not armed: the app keeps its own keyboard, unchanged.
      return KeyEventResult.ignored;
    }

    final intent = _translator.translate(event, modifiers);
    if (intent == null) {
      // Nothing to send — a lone modifier, or a key with no Android
      // equivalent. Still consumed: while armed, the app's shortcuts must not
      // fire behind the user's back.
      return KeyEventResult.handled;
    }
    if (!sink.send(intent)) {
      // The sink's own reason first. It knows which key was refused and why,
      // where the transport's [limitation] is one blanket sentence — telling
      // someone who pressed Page Down that "Cmd chords cannot be sent" would
      // send them hunting for a modifier problem they do not have.
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
    final armed = widget.forwarding && widget.sink != null;
    final live = armed && _hasFocus;
    return Column(
      children: [
        Expanded(
          child: Focus(
            focusNode: _node,
            onFocusChange: _onFocusChange,
            onKeyEvent: _onKey,
            child: Listener(
              // A raw listener rather than a tap recogniser: the live view's
              // own touch surface is one too, and a recogniser here would
              // compete with it in the gesture arena for every tap.
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _node.requestFocus(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: live ? theme.colorScheme.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
        _KeyboardBar(
          armed: armed,
          focused: _hasFocus,
          available: widget.sink != null,
          transport: widget.sink?.transport,
          deviceLabel: widget.deviceLabel,
          notice: _notice,
          onChanged: widget.sink == null ? null : _toggle,
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
    final (label, icon) = switch ((available, armed)) {
      (false, _) => (kKeyboardUnavailableLabel, AppIcons.warningCircle),
      (true, true) => (kKeyboardOnLabel, AppIcons.terminalWindow),
      (true, false) => (kKeyboardOffLabel, AppIcons.pauseCircle),
    };
    // What the transport cannot do is said while it is armed, focused or not:
    // finding out that Ctrl+C went nowhere by pressing it is not a report.
    final limits = transport?.limitation == null
        ? ''
        : '${transport!.limitation}. ';
    final detail = switch ((available, armed, focused)) {
      // Deliberately says *what* is missing without naming a transport: this
      // bar now sits under an Android mirror and an iOS simulator, and "no adb
      // fallback" is nonsense under the second one.
      (false, _, _) =>
        'Nothing here can carry a keystroke to this device, so it cannot be '
            'typed into.',
      (true, false, _) =>
        'Turn this on and your keyboard drives $device. '
            '$kDeviceKeyboardEscapeLabel toggles it from here.',
      (true, true, false) =>
        '${limits}Click the picture first — a background mirror is never '
            'typed into. $kDeviceKeyboardEscapeLabel to stop.',
      (true, true, true) =>
        '$limits'
            "Karmashala's own shortcuts now go to $device. "
            '$kDeviceKeyboardEscapeLabel to stop.',
    };
    final colour = armed
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;

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
            child: Switch(
              value: armed,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }
}
