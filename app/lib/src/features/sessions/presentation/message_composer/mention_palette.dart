// The `@` palette: what is being mentioned, its keys, the list over the box,
// and the sheet a thumb opens it as.

part of '../message_composer.dart';

mixin _ComposerMentioning on State<MessageComposer> {
  TextEditingController get _input;
  FocusNode get _focusNode;

  List<ComposerMentionOption> _mentionMatches = const [];
  int _mentionHighlight = 0;

  /// Where the "@…" being typed starts; null while none is.
  int? _mentionStart;

  /// Esc shut the palette for the "@" at this offset.
  int? _mentionDismissedAt;

  /// Each ask's number: an answer to an older one is dropped.
  int _mentionAsk = 0;

  bool get _mentionOpen => _mentionMatches.isNotEmpty;

  /// The "@…" the caret is at the end of — its start and what follows the
  /// "@" — or null when the caret is in no such word.
  static ({int start, String query})? typingMention(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final caret = selection.baseOffset;
    final text = value.text;
    var start = caret;
    while (start > 0 && text[start - 1].trim().isNotEmpty) {
      start--;
    }
    if (start < text.length && text[start] == '(') start++;
    if (start >= caret || text[start] != '@') return null;
    return (start: start, query: text.substring(start + 1, caret));
  }

  void _matchMentions() {
    final source = widget.mentions;
    final typing = source == null ? null : typingMention(_input.value);
    if (typing == null || typing.start != _mentionDismissedAt) {
      _mentionDismissedAt = null;
    }
    if (typing == null || _mentionDismissedAt != null) {
      _mentionAsk++;
      _mentionStart = null;
      if (_mentionMatches.isNotEmpty && mounted) {
        setState(() => _mentionMatches = const []);
      }
      return;
    }
    final ask = ++_mentionAsk;
    unawaited(
      source!
          .options(typing.query)
          .then(
            (options) {
              if (!mounted || ask != _mentionAsk) return;
              // A mention typed out whole is done: Enter sends rather than
              // picks it again.
              final typed = '@${typing.query}';
              final done = options.any(
                (o) => !o.continues && o.insert == typed,
              );
              setState(() {
                _mentionStart = typing.start;
                _mentionMatches = done ? const [] : options;
                _mentionHighlight = 0;
              });
            },
            onError: (Object e, StackTrace stack) {
              _log.warning('Mention options failed: $e', e, stack);
            },
          ),
    );
  }

  /// Puts [option] where the "@…" was. A kind ("@terminal:") leaves the
  /// list open on its own entries; anything else ends with a space.
  void _pickMention(ComposerMentionOption option) {
    final value = _input.value;
    final typing = typingMention(value);
    final start = typing?.start ?? _mentionStart ?? value.selection.baseOffset;
    final end = value.selection.isValid
        ? value.selection.baseOffset
        : value.text.length;
    final insert = option.continues ? option.insert : '${option.insert} ';
    _input.value = TextEditingValue(
      text: value.text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _focusNode.requestFocus();
  }

  /// Puts a mention picked from the sheet at the caret, spaced from the
  /// words around it.
  void _insertMention(String mention) {
    final value = _input.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final before = start > 0 && text[start - 1].trim().isNotEmpty ? ' ' : '';
    final insert = '$before$mention ';
    _input.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _focusNode.requestFocus();
  }

  KeyEventResult _handleMentionKey(KeyEvent event) {
    final key = event.logicalKey;
    final count = _mentionMatches.length;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _mentionHighlight = (_mentionHighlight + 1) % count);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _mentionHighlight = (_mentionHighlight - 1 + count) % count,
      );
    } else if (key == LogicalKeyboardKey.tab ||
        ((key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) &&
            !HardwareKeyboard.instance.isShiftPressed)) {
      _pickMention(_mentionMatches[_mentionHighlight]);
    } else if (key == LogicalKeyboardKey.escape) {
      _mentionAsk++;
      setState(() {
        _mentionDismissedAt = _mentionStart;
        _mentionMatches = const [];
      });
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// The same list as a sheet, with its own search: a phone has no "@" key
  /// to spare, and no arrows.
  Future<void> _openMentionSheet() async {
    final source = widget.mentions;
    if (source == null) return;
    final picked = await showAdaptiveModal<String>(
      context: context,
      title: 'Mention',
      builder: (context) => _MentionSheet(source: source),
    );
    if (picked != null && mounted) _insertMention(picked);
  }
}

IconData _mentionIcon(MentionKind kind) => switch (kind) {
  MentionKind.file => AppIcons.file,
  MentionKind.folder => AppIcons.folder,
  MentionKind.diff => AppIcons.gitDiff,
  MentionKind.terminal => AppIcons.terminal,
  MentionKind.session => AppIcons.chat,
  MentionKind.subagent => AppIcons.robot,
  MentionKind.url => AppIcons.linkSimple,
};

/// One entry of the palette or the sheet: the kind's glyph, the label, and
/// what it is in a quieter voice.
class _MentionRow extends StatelessWidget {
  const _MentionRow({
    required this.option,
    required this.highlighted,
    required this.touch,
    required this.onTap,
  });

  final ComposerMentionOption option;
  final bool highlighted;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = option.detail;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: ValueKey('composer-mention-${option.insert}'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            color: highlighted ? StateLayers.selected(scheme) : null,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          child: Row(
            children: [
              Icon(
                _mentionIcon(option.kind),
                size: touch ? Touch.icon : Chrome.icon,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Flexible(
                flex: 3,
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MonoStyles.label.copyWith(color: scheme.onSurface),
                ),
              ),
              if (detail != null && detail.isNotEmpty) ...[
                const SizedBox(width: Insets.sm),
                Expanded(
                  flex: 2,
                  child: Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ] else
                const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// What "@" can mention, matching what follows it, over the text. Up and
/// Down move, Enter or Tab picks, Esc shuts; a tap picks too.
class _MentionPalette extends StatelessWidget {
  const _MentionPalette({
    required this.options,
    required this.highlighted,
    required this.touch,
    required this.onPicked,
  });

  final List<ComposerMentionOption> options;
  final int highlighted;
  final bool touch;
  final ValueChanged<ComposerMentionOption> onPicked;

  /// What the palette adds to the composer, for its sizing.
  static double heightFor(int count, {required bool touch}) =>
      _CommandPalette.heightFor(count, touch: touch);

  @override
  Widget build(BuildContext context) {
    final rowHeight = _CommandPalette._rowHeight(touch: touch);
    return Padding(
      key: const ValueKey('composer-mention-palette'),
      padding: const EdgeInsets.fromLTRB(Insets.xs, Insets.sm, Insets.xs, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: _CommandPalette._shown * rowHeight,
        ),
        child: ListView.builder(
          shrinkWrap: true,
          primary: false,
          padding: EdgeInsets.zero,
          itemCount: options.length,
          itemExtent: rowHeight,
          itemBuilder: (context, i) => _MentionRow(
            option: options[i],
            highlighted: i == highlighted,
            touch: touch,
            onTap: () => onPicked(options[i]),
          ),
        ),
      ),
    );
  }
}

/// The palette as a sheet: a search field for what would follow "@", and the
/// entries under it. A kind narrows the list to its own; anything else is
/// handed back as the mention to insert.
class _MentionSheet extends StatefulWidget {
  const _MentionSheet({required this.source});

  final ComposerMentions source;

  @override
  State<_MentionSheet> createState() => _MentionSheetState();
}

class _MentionSheetState extends State<_MentionSheet> {
  final _query = TextEditingController();
  List<ComposerMentionOption> _options = const [];
  int _ask = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(_search);
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final ask = ++_ask;
    unawaited(
      widget.source
          .options(_query.text)
          .then(
            (options) {
              if (mounted && ask == _ask) setState(() => _options = options);
            },
            onError: (Object e, StackTrace stack) {
              _log.warning('Mention options failed: $e', e, stack);
            },
          ),
    );
  }

  void _picked(ComposerMentionOption option) {
    if (!option.continues) {
      Navigator.of(context).pop(option.insert);
      return;
    }
    final query = option.insert.substring(1);
    _query.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Insets.md),
        child: SearchField(
          key: const ValueKey('composer-mention-search'),
          controller: _query,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'A file, diff, terminal, session or link',
          ),
        ),
      ),
      const SizedBox(height: Insets.sm),
      Flexible(
        child: ListView.builder(
          shrinkWrap: true,
          primary: false,
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          itemCount: _options.length,
          itemExtent: Touch.target,
          itemBuilder: (context, i) => _MentionRow(
            option: _options[i],
            highlighted: false,
            touch: true,
            onTap: () => _picked(_options[i]),
          ),
        ),
      ),
    ],
  );
}
