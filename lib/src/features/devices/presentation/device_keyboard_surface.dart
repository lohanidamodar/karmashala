import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/widgets/keyboard_capture.dart';
import 'package:karmashala_devices/devices.dart';

import 'desktop_key_bridge.dart';

/// What the bar says the keyboard is doing. Public so a test asserts the same
/// words the user reads.
const String kKeyboardOnLabel = 'Typing goes to the device';
const String kKeyboardOffLabel = 'Typing stays in Karmashala';
const String kKeyboardUnavailableLabel = 'Keyboard forwarding unavailable';

/// The keyboard target laid over the live view, and the state line under it.
///
/// The owner asked for this: "can we send keyboard events in live when actively
/// focused there? with a option to stop sending keyboard?" Both halves matter,
/// and the second is what makes the first safe to use.
///
/// **Focus is the switch.** The first version had a separate toggle that had to
/// be armed before anything was forwarded, and the owner's verdict on trying it
/// was that they "reached for the pane expecting to type into it and nothing
/// happened" — so clicking the picture now focuses it *and* starts forwarding.
/// The reasoning that motivated the toggle has not gone away, it has moved into
/// the three properties below: what a keyboard-capturing pane must never be is
/// *invisible*, *inescapable*, or *still running when you have looked away*.
///
/// * it forwards only while this pane actually **has focus**, so a mirror in a
///   background pane never sees a keystroke and looking away is enough to stop;
/// * [kDeviceKeyboardEscape] is reserved — never translated, never sent — and
///   suspends forwarding from a pane that has it, so there is always a way back
///   even though the pane is eating every shortcut the app has;
/// * the current state is written on screen in words, not signalled by colour,
///   and the switch stays as the mouse's way to the same place.
///
/// **Armed, this pane eats the app's shortcuts.** That is the feature — Ctrl+W
/// has to close a tab on the phone rather than in Karmashala — and while it is
/// armed the pane is wrapped in a [KeyboardCaptureScope] so nothing else in the
/// app moves the keyboard out from under it.
///
/// One surface for both platforms. Android arrives here with a scrcpy or adb
/// sink and iOS with a WebDriverAgent one; everything above the sink — focus,
/// arming, the escape chord, the wording, what happens to a refused key — is
/// this widget's, so the two cannot drift into behaving differently.
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

  /// Whether the user has explicitly told this pane to stop.
  ///
  /// The state is "suspended", not "armed", because arming is no longer an act
  /// — focus is. Only [kDeviceKeyboardEscape] and the switch set this, and it
  /// is deliberately **not** cleared on focus loss: someone who turned
  /// forwarding off, clicked away and clicked back has not asked for it again.
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
      // The transport changed under us — the control socket dropped and the adb
      // fallback took over, or the live view moved to another device. Whatever
      // the old one still believed was held is not ours to lift through the new
      // one, so the translator is reset rather than replayed.
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
    // Losing focus stops forwarding, so anything still held has to be lifted or
    // the device believes it is held forever — an arrow key left down scrolls a
    // list to the bottom on its own.
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
      // Suspended, or nothing to send through: the app keeps its own keyboard,
      // unchanged. Not consumed — a key that is not going to the device should
      // go back to Karmashala rather than nowhere.
      return KeyEventResult.ignored;
    }

    final intent = _translator.translate(desktopEvent, modifiers);
    if (intent == null) {
      // Nothing to send — a lone modifier, or a key with no equivalent on the
      // device. Still consumed: while armed, the app's shortcuts must not fire
      // behind the user's back.
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
    Widget picture = Focus(
      focusNode: _node,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKey,
      child: Listener(
        // A raw listener rather than a tap recogniser: the live view's own
        // touch surface is one too, and a recogniser here would compete with
        // it in the gesture arena for every tap.
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
      // Only while armed. A mirror that is not forwarding has no claim on the
      // keyboard, and marking it would pin focus away from the terminal for no
      // reason. See [KeyboardCaptureScope] for what this stops.
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
    // The headline is about where the keys are going *now*, not about what is
    // configured: armed but unfocused is not typing into the device, and saying
    // it is would be the invisible-capture trap in reverse.
    final live = armed && focused;
    final (label, icon) = switch ((available, live)) {
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
      // bar sits under an Android mirror and an iOS simulator alike, and "no
      // adb fallback" is nonsense under the second one.
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
