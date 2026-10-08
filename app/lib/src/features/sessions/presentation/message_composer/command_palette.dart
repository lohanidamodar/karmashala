// The slash-command palette: matching, its keys, and the list drawn over the box.

part of '../message_composer.dart';

mixin _ComposerCommands on State<MessageComposer> {
  TextEditingController get _input;
  FocusNode get _focusNode;

  /// The commands matching what follows a leading "/", while the command
  /// itself is still being typed; empty when the palette is shut.
  List<ComposerCommand> _commandMatches = const [];
  int _commandHighlight = 0;

  /// Esc shut the palette for this "/…": it opens again once the box no
  /// longer starts a command.
  bool _commandsDismissed = false;

  bool get _paletteOpen => _commandMatches.isNotEmpty;

  void _matchCommands() {
    final text = _input.text;
    final typing = text.startsWith('/') && !text.contains(RegExp(r'\s'));
    if (!typing) _commandsDismissed = false;
    var matches = const <ComposerCommand>[];
    final offered = widget.commands;
    if (typing && !_commandsDismissed && offered != null) {
      final query = text.substring(1);
      final found = [
        for (final c in offered())
          if (searchMatch(query, c.name) case final match?)
            (command: c, prefix: match.positions.firstOrNull == 0),
      ];
      // Names the query starts first, each half in the offered order.
      matches = [
        for (final f in found)
          if (f.prefix) f.command,
        for (final f in found)
          if (!f.prefix) f.command,
      ];
    }
    if (!mounted || _sameCommands(matches, _commandMatches)) return;
    setState(() {
      _commandMatches = matches;
      _commandHighlight = 0;
    });
  }

  static bool _sameCommands(List<ComposerCommand> a, List<ComposerCommand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i]) && a[i].name != b[i].name) return false;
    }
    return true;
  }

  /// Puts "/name " in the box, ready for its input; nothing is sent.
  void _pickCommand(ComposerCommand command) {
    final text = '/${command.name} ';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focusNode.requestFocus();
  }

  KeyEventResult _handlePaletteKey(KeyEvent event) {
    final key = event.logicalKey;
    final count = _commandMatches.length;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _commandHighlight = (_commandHighlight + 1) % count);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _commandHighlight = (_commandHighlight - 1 + count) % count,
      );
    } else if (key == LogicalKeyboardKey.tab ||
        ((key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) &&
            !HardwareKeyboard.instance.isShiftPressed)) {
      _pickCommand(_commandMatches[_commandHighlight]);
    } else if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _commandsDismissed = true;
        _commandMatches = const [];
      });
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}

/// The agent's slash commands matching what follows the "/", over the text:
/// the name, its input hint, and the agent's description. Up and Down move,
/// Enter or Tab picks, Esc shuts; a tap picks too.
class _CommandPalette extends StatelessWidget {
  const _CommandPalette({
    required this.commands,
    required this.highlighted,
    required this.touch,
    required this.onPicked,
  });

  final List<ComposerCommand> commands;
  final int highlighted;
  final bool touch;
  final ValueChanged<ComposerCommand> onPicked;

  /// Rows shown before the list scrolls.
  static const _shown = 6;

  static double _rowHeight({required bool touch}) =>
      touch ? Touch.target : Chrome.menuRow;

  /// What the palette adds to the composer, for its sizing.
  static double heightFor(int count, {required bool touch}) =>
      math.min(count, _shown) * _rowHeight(touch: touch) + Insets.sm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final rowHeight = _rowHeight(touch: touch);
    return Padding(
      key: const ValueKey('composer-command-palette'),
      padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.sm, Insets.xs, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: _shown * rowHeight),
        child: ListView.builder(
          shrinkWrap: true,
          primary: false,
          padding: EdgeInsets.zero,
          itemCount: commands.length,
          itemExtent: rowHeight,
          itemBuilder: (context, i) {
            final command = commands[i];
            final hint = command.hint;
            return Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey('composer-command-${command.name}'),
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: () => onPicked(command),
                child: Ink(
                  decoration: BoxDecoration(
                    color: i == highlighted
                        ? StateLayers.selected(scheme)
                        : null,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                  child: Row(
                    children: [
                      Text(
                        '/${command.name}',
                        style: MonoStyles.label.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                      if (hint != null && hint.isNotEmpty) ...[
                        const SizedBox(width: Insets.xs),
                        Flexible(
                          child: Text(
                            hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: MonoStyles.body.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          command.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
