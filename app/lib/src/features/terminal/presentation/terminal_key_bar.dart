import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:xterm2/xterm.dart';

/// The extra keys a soft keyboard lacks, in one row under a focused pane at
/// touch density (Stage 2 step 10). Every key goes through the terminal's
/// `keyInput` or `textInput`, the road a typed key takes, so the session's
/// input rules apply to it unchanged.
class TerminalKeyBar extends StatefulWidget {
  const TerminalKeyBar({
    required this.terminal,
    required this.focusNode,
    super.key,
  });

  final Terminal terminal;

  /// The pane's own: the row shows only while it has focus.
  final FocusNode focusNode;

  @override
  State<TerminalKeyBar> createState() => _TerminalKeyBarState();
}

class _TerminalKeyBarState extends State<TerminalKeyBar> {
  late _StickyModifiers _sticky;

  @override
  void initState() {
    super.initState();
    _install(widget.terminal);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(TerminalKeyBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      _uninstall(oldWidget.terminal);
      _install(widget.terminal);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    _uninstall(widget.terminal);
    super.dispose();
  }

  /// Sticky modifiers wrap the terminal's input handler, so they reach the
  /// soft keyboard's next key as well as the row's own.
  void _install(Terminal terminal) {
    _sticky = _StickyModifiers(terminal.inputHandler);
    terminal.inputHandler = _sticky;
  }

  void _uninstall(Terminal terminal) {
    if (identical(terminal.inputHandler, _sticky)) {
      terminal.inputHandler = _sticky.inner;
    }
    _sticky.dispose();
  }

  void _onFocusChanged() {
    if (!widget.focusNode.hasFocus) _sticky.clear();
    setState(() {});
  }

  /// One key, with whichever modifiers are armed, then disarmed. A character
  /// no handler claims is typed as text, Alt as its ESC prefix.
  void _press(TerminalKey key, [String? text]) {
    final ctrl = _sticky.ctrl;
    final alt = _sticky.alt;
    _sticky.clear();
    final terminal = widget.terminal;
    if (terminal.keyInput(key, ctrl: ctrl, alt: alt, text: text)) return;
    if (text != null) terminal.textInput(alt ? '\x1b$text' : text);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.focusNode.hasFocus) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    Widget plain(
      String label,
      String semantics,
      TerminalKey terminalKey, [
      String? text,
    ]) => _BarKey(
      label: label,
      semantics: semantics,
      onPressed: () => _press(terminalKey, text),
    );
    // Focus stays in the pane: a key that took it would drop the keyboard.
    return ExcludeFocus(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: ListenableBuilder(
          listenable: _sticky,
          builder: (context, _) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
            child: Row(
              children: [
                plain('Esc', 'Escape', TerminalKey.escape),
                plain('Tab', 'Tab', TerminalKey.tab),
                _BarKey(
                  label: 'Ctrl',
                  semantics: 'Control, applies to the next key',
                  armed: _sticky.ctrl,
                  onPressed: _sticky.toggleCtrl,
                ),
                _BarKey(
                  label: 'Alt',
                  semantics: 'Alt, applies to the next key',
                  armed: _sticky.alt,
                  onPressed: _sticky.toggleAlt,
                ),
                plain('↑', 'Up arrow', TerminalKey.arrowUp),
                plain('↓', 'Down arrow', TerminalKey.arrowDown),
                plain('←', 'Left arrow', TerminalKey.arrowLeft),
                plain('→', 'Right arrow', TerminalKey.arrowRight),
                plain('|', 'Pipe', TerminalKey.none, '|'),
                plain('~', 'Tilde', TerminalKey.none, '~'),
                plain('/', 'Slash', TerminalKey.slash, '/'),
                plain('-', 'Minus', TerminalKey.minus, '-'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarKey extends StatelessWidget {
  const _BarKey({
    required this.label,
    required this.semantics,
    required this.onPressed,
    this.armed,
  });

  final String label;
  final String semantics;
  final VoidCallback onPressed;

  /// Null for a key that is not sticky.
  final bool? armed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = armed ?? false;
    return Semantics(
      button: true,
      toggled: armed,
      label: semantics,
      excludeSemantics: true,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, Touch.target),
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: on ? scheme.primaryContainer : null,
          foregroundColor: on ? scheme.onPrimaryContainer : scheme.onSurface,
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontFamily: kMonoFamily,
            color: on ? scheme.onPrimaryContainer : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// Ctrl and Alt held for one key: the row's next, or the soft keyboard's.
class _StickyModifiers extends ChangeNotifier implements TerminalInputHandler {
  _StickyModifiers(this.inner);

  /// The handler the terminal had, which still encodes every key.
  final TerminalInputHandler? inner;

  bool ctrl = false;
  bool alt = false;

  void toggleCtrl() {
    ctrl = !ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    alt = !alt;
    notifyListeners();
  }

  void clear() {
    if (!ctrl && !alt) return;
    ctrl = false;
    alt = false;
    notifyListeners();
  }

  @override
  String? call(TerminalKeyboardEvent event) {
    final inner = this.inner;
    if (inner == null) return null;
    if ((!ctrl && !alt) ||
        event.type == TerminalKeyEventType.release ||
        _isModifier(event.key)) {
      return inner(event);
    }
    final withAlt = alt;
    final modified = event.copyWith(
      ctrl: event.ctrl || ctrl,
      alt: event.alt || alt,
    );
    clear();
    final encoded = inner(modified);
    if (encoded != null) return encoded;
    final text = event.text;
    if (withAlt && text != null && text.runes.length == 1) return '\x1b$text';
    return inner(event);
  }

  static bool _isModifier(TerminalKey key) => switch (key) {
    TerminalKey.controlLeft ||
    TerminalKey.controlRight ||
    TerminalKey.shiftLeft ||
    TerminalKey.shiftRight ||
    TerminalKey.altLeft ||
    TerminalKey.altRight ||
    TerminalKey.metaLeft ||
    TerminalKey.metaRight => true,
    _ => false,
  };
}
