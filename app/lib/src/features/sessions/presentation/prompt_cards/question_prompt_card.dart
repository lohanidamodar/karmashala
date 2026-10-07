import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/client.dart' show GatewayException;

/// Answers an agent's multiple-choice question from the phone.
typedef CompanionQuestionAnswerFn =
    Future<void> Function(
      List<RemoteQuestionAnswer> answers, {
      bool decline,
      bool chat,
    });

/// What Send does, said as its tooltip rather than a line under it.
const _sendHint = "Your choice is typed into the session's terminal.";

/// The least height of an option row under a thumb.
const double _touchRow = 44;

/// An agent's multiple-choice question as a compact card: a slim header, the
/// question clamped, a dense row per option, an own-words row on a
/// single-choice one, and one row of answers. **No Approve**: on a question
/// the approve key is Enter, which answers with the highlighted option
/// instead of the one the user wanted.
class QuestionPromptCard extends StatefulWidget {
  const QuestionPromptCard({
    required this.agentName,
    required this.question,
    required this.onAnswer,
    this.canAnswer = true,
    this.chatLabel,
    this.showHeader = true,
    this.where,
    this.trailing,
    this.onAnswerInTerminal,
    this.dense = false,
    this.numbered = false,
    this.onReplyInWords,
    this.controller,
    super.key,
  });

  /// Each option under its number, the key that picks it on the Overview's
  /// board, with Decline in sight rather than under ⋯.
  final bool numbered;

  /// "Reply in words", in sight beside Decline; null draws none.
  final VoidCallback? onReplyInWords;

  /// Picks and sends from outside the card: the Overview's keys.
  final QuestionPromptController? controller;

  final String agentName;
  final RemoteQuestion question;
  final CompanionQuestionAnswerFn onAnswer;

  /// Whether this phone holds the `approve` capability.
  final bool canAnswer;

  /// The agent's own row for leaving the question to talk it over ("Chat
  /// about this"), offered as its own action; null when it draws none.
  final String? chatLabel;

  /// Whether the card draws its own header line.
  final bool showHeader;

  /// Where the asking session runs ("in karmashala"), said beside the agent.
  final String? where;

  /// At the header's end — how long the question has waited.
  final Widget? trailing;

  /// Takes the user to the session's terminal; null when it has none.
  final VoidCallback? onAnswerInTerminal;

  /// Tighter still, for a queue of questions: two lines of question, one of
  /// each description, and the secondary answers always under ⋯.
  final bool dense;

  @override
  State<QuestionPromptCard> createState() => _QuestionPromptCardState();
}

/// Picks and sends a [QuestionPromptCard]'s answer from outside it, through
/// the card's own Send.
class QuestionPromptController {
  _QuestionPromptCardState? _card;

  /// Picks option [index] of the first question; false when it has none.
  bool pick(int index) => _card?._pickFromKeys(index) ?? false;

  /// Sends what is picked; false when no complete answer is.
  bool send() => _card?._sendFromKeys() ?? false;
}

enum _Secondary { decline, chat, terminal }

class _QuestionPromptCardState extends State<QuestionPromptCard> {
  /// The options chosen per question.
  late List<Set<int>> _chosen = _fresh();

  /// Per question, whether "Other…" is chosen, and its words.
  late List<bool> _other = _freshOther();
  late List<TextEditingController> _words = _freshWords();

  /// Descriptions opened without being chosen, as `(question, option)`.
  final _opened = <(int, int)>{};

  /// Questions whose text is shown whole, and options whose preview is open.
  final _wholeText = <int>{};
  final _previews = <(int, int)>{};

  bool _busy = false;

  final _options = ScrollController();

  List<Set<int>> _fresh() => [
    for (final _ in widget.question.questions) <int>{},
  ];
  List<bool> _freshOther() => [
    for (final _ in widget.question.questions) false,
  ];
  List<TextEditingController> _freshWords() => [
    for (final _ in widget.question.questions) TextEditingController(),
  ];

  @override
  void initState() {
    super.initState();
    widget.controller?._card = this;
  }

  bool _pickFromKeys(int index) {
    final questions = widget.question.questions;
    if (_busy || !widget.canAnswer || questions.isEmpty) return false;
    if (index < 0 || index >= questions.first.options.length) return false;
    _pick(0, index);
    return true;
  }

  bool _sendFromKeys() {
    if (_busy || !widget.canAnswer || !_complete) return false;
    _send();
    return true;
  }

  @override
  void didUpdateWidget(QuestionPromptCard old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._card == this) old.controller!._card = null;
      widget.controller?._card = this;
    }
    // A new question is a new form: nothing chosen for the last one carries.
    if (old.question.toolUseId != widget.question.toolUseId) {
      for (final c in _words) {
        c.dispose();
      }
      _chosen = _fresh();
      _other = _freshOther();
      _words = _freshWords();
      _opened.clear();
      _wholeText.clear();
      _previews.clear();
    }
  }

  @override
  void dispose() {
    if (widget.controller?._card == this) widget.controller!._card = null;
    for (final c in _words) {
      c.dispose();
    }
    _options.dispose();
    super.dispose();
  }

  bool _answered(int i) =>
      _other[i] ? _words[i].text.trim().isNotEmpty : _chosen[i].isNotEmpty;

  bool get _complete =>
      [for (var i = 0; i < _chosen.length; i++) _answered(i)].every((a) => a);

  List<RemoteQuestionAnswer> get _answers => [
    for (var i = 0; i < _chosen.length; i++)
      _other[i]
          ? RemoteQuestionAnswer.text(_words[i].text.trim())
          : RemoteQuestionAnswer.options(_chosen[i].toList()..sort()),
  ];

  Future<void> _send({bool decline = false, bool chat = false}) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onAnswer(
        decline || chat ? const [] : _answers,
        decline: decline,
        chat: chat,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is GatewayException ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pick(int question, int option) => setState(() {
    final item = widget.question.questions[question];
    _other[question] = false;
    if (item.multiSelect) {
      final chosen = _chosen[question];
      if (!chosen.remove(option)) chosen.add(option);
    } else {
      _chosen[question] = {option};
    }
  });

  void _toggle<T>(Set<T> set, T value) =>
      setState(() => set.remove(value) || set.add(value));

  /// Brings the option at [context] wholly into view once it has redrawn.
  void _reveal(BuildContext context) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        for (final policy in const [
          ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        ]) {
          Scrollable.ensureVisible(context, alignmentPolicy: policy);
        }
      });

  @override
  Widget build(BuildContext context) {
    final questions = widget.question.questions;
    return LayoutBuilder(
      builder: (context, box) {
        final compact =
            widget.dense ||
            WidthClass.of(
              box.maxWidth,
              textScaler: MediaQuery.textScalerOf(context),
            ).isCompact;
        final options = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < questions.length; i++) ...[
              if (i > 0) const SizedBox(height: Insets.sm),
              _question(context, i),
            ],
          ],
        );
        // Held to a height, the question scrolls as a whole and the answers
        // stay pinned under it: a tall one once pushed its answers away.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showHeader) _header(context, compact),
            if (box.hasBoundedHeight)
              Flexible(
                child: Scrollbar(
                  controller: _options,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    key: const ValueKey('question-options'),
                    controller: _options,
                    primary: false,
                    child: options,
                  ),
                ),
              )
            else
              KeyedSubtree(
                key: const ValueKey('question-options'),
                child: options,
              ),
            _actions(context, compact),
          ],
        );
      },
    );
  }

  String get _who {
    final count = widget.question.questions.length;
    return '${widget.agentName} is asking you '
        '${count == 1 ? 'a question' : '$count questions'}'
        '${widget.where == null ? '' : ' · ${widget.where}'}';
  }

  /// One line: what the question is about, then — where there is room — who
  /// asks, and the [QuestionPromptCard.trailing] at its end.
  Widget _header(BuildContext context, bool compact) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final questions = widget.question.questions;
    final label = questions.length > 1
        ? '${questions.length} questions'
        : questions.single.header.isNotEmpty
        ? questions.single.header
        : 'Question';
    final trailing = widget.trailing;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: Tooltip(
        message: _who,
        child: Row(
          key: const ValueKey('question-header'),
          children: [
            Icon(
              AppIcons.question,
              size: density.icon,
              color: SemanticColors.of(context).attention,
            ),
            SizedBox(width: density.glyphGap),
            Expanded(
              flex: compact ? 1 : 3,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: Insets.sm),
                    Flexible(
                      flex: 3,
                      child: Text(
                        _who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: density.muted(theme),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Insets.sm),
              // Held to a share of the line, so a large text scale shortens
              // the clock rather than the question's name.
              Flexible(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: DefaultTextStyle.merge(
                    overflow: TextOverflow.ellipsis,
                    child: trailing,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Send at the end; Decline and Chat beside it where there is room, and
  /// under ⋯ with the way to the terminal where there is not.
  Widget _actions(BuildContext context, bool compact) {
    final theme = Theme.of(context);
    if (!widget.canAnswer) {
      return Padding(
        padding: const EdgeInsets.only(top: Insets.xs),
        child: Text(
          'This phone was not granted approval rights, so it cannot answer. '
          'Answer in its terminal.',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      );
    }
    final chat = widget.chatLabel;
    // Numbered, Decline is in sight however narrow; the rest folds under ⋯.
    final inSight = !compact || widget.numbered;
    final menu = [
      if (!inSight) _Secondary.decline,
      if (compact && chat != null) _Secondary.chat,
      if (widget.onAnswerInTerminal != null) _Secondary.terminal,
    ];
    final reply = widget.onReplyInWords;
    String labelOf(_Secondary action) => switch (action) {
      _Secondary.decline => 'Decline',
      _Secondary.chat => chat ?? '',
      _Secondary.terminal => 'Answer in the terminal',
    };
    void run(_Secondary action) => switch (action) {
      _Secondary.decline => _send(decline: true),
      _Secondary.chat => _send(chat: true),
      _Secondary.terminal => widget.onAnswerInTerminal?.call(),
    };
    final quiet = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      visualDensity: UiDensity.of(context).controlDensity,
    );
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: !inSight
                ? const SizedBox.shrink()
                : Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (reply != null)
                        TextButton(
                          key: const ValueKey('question-reply-in-words'),
                          style: quiet,
                          onPressed: _busy ? null : reply,
                          child: const Text('Reply in words'),
                        ),
                      TextButton(
                        key: const ValueKey('question-decline'),
                        style: quiet,
                        onPressed: _busy ? null : () => run(_Secondary.decline),
                        child: const Text('Decline'),
                      ),
                      if (chat != null && !compact)
                        TextButton(
                          style: quiet,
                          onPressed: _busy
                              ? null
                              : () => run(_Secondary.chat),
                          child: Text(
                            chat,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
          ),
          if (menu.isNotEmpty)
            PopupMenuButton<_Secondary>(
              key: const ValueKey('question-more-actions'),
              tooltip: 'More answers',
              enabled: !_busy,
              icon: Icon(
                AppIcons.dotsThree,
                size: UiDensity.of(context).iconSize(Chrome.icon) + 2,
                color: theme.colorScheme.onSurface,
              ),
              onSelected: run,
              itemBuilder: (_) => [
                for (final action in menu)
                  PopupMenuItem(value: action, child: Text(labelOf(action))),
              ],
            ),
          const SizedBox(width: Insets.xs),
          Tooltip(
            message: _sendHint,
            child: FilledButton(
              key: const ValueKey('question-send'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
              ),
              onPressed: _busy || !_complete ? null : _send,
              child: const Text('Send'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _question(BuildContext context, int i) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final item = widget.question.questions[i];
    final single = widget.question.questions.length == 1;
    final interactive = !_busy && widget.canAnswer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Said once: a lone question's header is the card's own.
        if (item.header.isNotEmpty && (!single || !widget.showHeader))
          Text(
            item.header.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        _Clamped(
          textKey: ValueKey('question-text-$i'),
          toggleKey: ValueKey('question-text-more-$i'),
          text: item.question,
          style: theme.textTheme.bodyMedium,
          lines: widget.dense ? 2 : 3,
          whole: _wholeText.contains(i),
          onToggle: () => _toggle(_wholeText, i),
        ),
        if (item.multiSelect) Text('Choose any.', style: density.muted(theme)),
        SizedBox(height: density.lineGap),
        for (var o = 0; o < item.options.length; o++)
          Builder(
            builder: (row) {
              final option = item.options[o];
              final selected = !_other[i] && _chosen[i].contains(o);
              return _OptionRow(
                key: ValueKey('question-option-$i-$o'),
                id: '$i-$o',
                label: option.label,
                description: option.description,
                multi: item.multiSelect,
                selected: selected,
                opened: _opened.contains((i, o)),
                dense: widget.dense,
                // Only the first question's options have keys to pick them.
                number: widget.numbered && i == 0 && o < 9 ? o + 1 : null,
                preview: selected ? option.preview : '',
                previewOpen: _previews.contains((i, o)),
                onTogglePreview: () => _toggle(_previews, (i, o)),
                onToggleOpen: () => _toggle(_opened, (i, o)),
                onTap: !interactive
                    ? null
                    : () {
                        _pick(i, o);
                        _reveal(row);
                      },
              );
            },
          ),
        // Own words were measured for a single-choice question only.
        if (!item.multiSelect) ...[
          Builder(
            builder: (row) => _OptionRow(
              key: ValueKey('question-option-$i-other'),
              id: '$i-other',
              label: 'Other…',
              description: '',
              multi: false,
              selected: _other[i],
              dense: widget.dense,
              onTap: !interactive
                  ? null
                  : () {
                      setState(() {
                        _other[i] = true;
                        _chosen[i] = {};
                      });
                      _reveal(row);
                    },
            ),
          ),
          if (_other[i])
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: density.icon + density.glyphGap,
              ),
              child: TextField(
                key: ValueKey('question-other-field-$i'),
                controller: _words[i],
                autofocus: true,
                maxLines: 1,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Your answer',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
        ],
      ],
    );
  }
}

/// Text held to [lines] with a "more" to show it whole, offered only when it
/// does not fit.
class _Clamped extends StatelessWidget {
  const _Clamped({
    required this.textKey,
    required this.toggleKey,
    required this.text,
    required this.style,
    required this.lines,
    required this.whole,
    required this.onToggle,
  });

  final Key textKey;
  final Key toggleKey;
  final String text;
  final TextStyle? style;
  final int lines;
  final bool whole;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: DefaultTextStyle.of(context).style.merge(style),
        ),
        maxLines: lines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: box.maxWidth);
      final overflows = painter.didExceedMaxLines;
      painter.dispose();
      final shown = Text(
        text,
        key: textKey,
        style: style,
        maxLines: whole ? null : lines,
        overflow: whole ? null : TextOverflow.ellipsis,
      );
      if (!overflows && !whole) return shown;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            shown,
            Text(
              whole ? 'less' : 'more',
              key: toggleKey,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// One option as a dense row: a radio, or a box when several may be chosen;
/// the label with a "Recommended" badge in place of the agent's suffix; the
/// description held to two lines unless chosen or opened.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required super.key,
    required this.id,
    required this.label,
    required this.description,
    required this.multi,
    required this.selected,
    required this.onTap,
    required this.dense,
    this.number,
    this.opened = false,
    this.preview = '',
    this.previewOpen = false,
    this.onToggleOpen,
    this.onTogglePreview,
  });

  /// `question-option` key suffix for the row's parts.
  final String id;
  final String label;
  final String description;
  final bool multi;
  final bool selected;
  final bool opened;
  final bool dense;

  /// Drawn in place of the radio: the key that picks this option.
  final int? number;

  /// The chosen option's preview; empty when it has none or is not chosen.
  final String preview;
  final bool previewOpen;
  final VoidCallback? onTap;
  final VoidCallback? onToggleOpen;
  final VoidCallback? onTogglePreview;

  static final _recommended = RegExp(
    r'\s*\(recommended\)',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final recommended = _recommended.hasMatch(label);
    final name = recommended
        ? label.replaceFirst(_recommended, '').trim()
        : label;
    final icon = multi
        ? (selected ? AppIcons.check : AppIcons.square)
        : (selected ? AppIcons.checkCircle : AppIcons.circle);
    final hasDescription = description.isNotEmpty && description != label;
    final whole = selected || opened;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: hasDescription ? onToggleOpen : null,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: density.isTouch ? _touchRow : 0,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: number == null
                      ? Icon(
                          icon,
                          size: density.icon,
                          color: selected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        )
                      : _NumberCap(number: number!, selected: selected),
                ),
                SizedBox(width: density.glyphGap + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: Insets.xs + 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(name, style: theme.textTheme.bodyMedium),
                          if (recommended) const _Badge('Recommended'),
                        ],
                      ),
                      if (hasDescription) _description(context, whole: whole),
                      if (preview.isNotEmpty) ..._preview(context),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _description(BuildContext context, {required bool whole}) {
    final theme = Theme.of(context);
    final density = UiDensity.of(context);
    final style = density.muted(theme);
    final lines = dense ? 1 : 2;
    final chevron = density.isTouch ? 32.0 : 24.0;
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(
            text: description,
            style: DefaultTextStyle.of(context).style.merge(style),
          ),
          maxLines: lines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: box.maxWidth - chevron);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        // A chosen option's description is always whole: no chevron to fold.
        final canFold = !selected && (overflows || opened);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                description,
                key: ValueKey('question-option-desc-$id'),
                style: style,
                maxLines: whole ? null : lines,
                overflow: whole ? null : TextOverflow.ellipsis,
              ),
            ),
            if (canFold)
              SizedBox.square(
                dimension: chevron,
                child: IconButton(
                  key: ValueKey('question-option-expand-$id'),
                  padding: EdgeInsets.zero,
                  iconSize: density.iconSmall,
                  tooltip: opened ? 'Show less' : 'Show more',
                  onPressed: onToggleOpen,
                  icon: Icon(opened ? AppIcons.caretUp : AppIcons.caretDown),
                ),
              )
            else
              SizedBox(width: chevron),
          ],
        );
      },
    );
  }

  List<Widget> _preview(BuildContext context) => [
    TextButton(
      key: ValueKey('question-preview-toggle-$id'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
        visualDensity: UiDensity.of(context).controlDensity,
      ),
      onPressed: onTogglePreview,
      child: Text(previewOpen ? 'Hide preview' : 'Show preview'),
    ),
    if (previewOpen)
      Container(
        key: ValueKey('question-preview-$id'),
        constraints: const BoxConstraints(maxHeight: 240),
        padding: const EdgeInsets.all(Insets.sm),
        decoration: BoxDecoration(
          color: SurfaceTones.of(context).term,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        // Drawn as written: a mockup's columns are its meaning.
        child: SingleChildScrollView(
          primary: false,
          child: SingleChildScrollView(
            primary: false,
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              preview,
              style: MonoStyles.body.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
  ];
}

/// An option's number in a small box, filled when chosen.
class _NumberCap extends StatelessWidget {
  const _NumberCap({required this.number, required this.selected});

  final int number;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final side = UiDensity.of(context).icon;
    return Container(
      constraints: BoxConstraints(minWidth: side, minHeight: side),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : null,
        border: Border.all(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(Insets.xs),
      ),
      child: Text(
        '$number',
        style: theme.textTheme.labelSmall?.copyWith(
          color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A word in a small rounded tag beside a label.
class _Badge extends StatelessWidget {
  const _Badge(this.word);

  final String word;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: Insets.hair),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: StateLayers.selectedAlpha),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(
        word,
        style: theme.textTheme.labelSmall?.copyWith(color: accent),
      ),
    );
  }
}

/// One option to tap: a radio, or a box when several may be chosen.
class CompanionChoice extends StatelessWidget {
  const CompanionChoice({
    super.key,
    required this.label,
    required this.description,
    required this.multi,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String description;
  final bool multi;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final icon = multi
        ? (selected ? AppIcons.check : AppIcons.square)
        : (selected ? AppIcons.checkCircle : AppIcons.circle);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: density.minRow),
          child: Row(
            children: [
              Icon(
                icon,
                size: density.icon,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              SizedBox(width: density.glyphGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium),
                    if (description.isNotEmpty && description != label)
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
