import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/client.dart' show GatewayException;

part 'question_prompt_card/option_rows.dart';

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
                          onPressed: _busy ? null : () => run(_Secondary.chat),
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
