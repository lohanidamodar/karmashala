import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';

/// Answers an agent's multiple-choice question from the phone.
typedef CompanionQuestionAnswerFn =
    Future<void> Function(
      List<RemoteQuestionAnswer> answers, {
      bool decline,
    });

/// An agent's multiple-choice question: each question's options to tap, an
/// own-words box on a single-choice one, and a decline. **No Approve**: on a
/// question the approve key is Enter, which answers with the highlighted
/// option instead of the one the user wanted.
class CompanionQuestionCard extends StatefulWidget {
  const CompanionQuestionCard({
    required this.agentName,
    required this.question,
    required this.onAnswer,
    this.canAnswer = true,
    super.key,
  });

  final String agentName;
  final RemoteQuestion question;
  final CompanionQuestionAnswerFn onAnswer;

  /// Whether this phone holds the `approve` capability.
  final bool canAnswer;

  @override
  State<CompanionQuestionCard> createState() => _CompanionQuestionCardState();
}

class _CompanionQuestionCardState extends State<CompanionQuestionCard> {
  /// The options chosen per question.
  late List<Set<int>> _chosen = _fresh();

  /// Per question, whether "Other…" is chosen, and its words.
  late List<bool> _other = _freshOther();
  late List<TextEditingController> _words = _freshWords();

  bool _busy = false;

  List<Set<int>> _fresh() => [
    for (final _ in widget.question.questions) <int>{},
  ];
  List<bool> _freshOther() => [for (final _ in widget.question.questions) false];
  List<TextEditingController> _freshWords() => [
    for (final _ in widget.question.questions) TextEditingController(),
  ];

  @override
  void didUpdateWidget(CompanionQuestionCard old) {
    super.didUpdateWidget(old);
    // A new question is a new form: nothing chosen for the last one carries.
    if (old.question.toolUseId != widget.question.toolUseId) {
      for (final c in _words) {
        c.dispose();
      }
      _chosen = _fresh();
      _other = _freshOther();
      _words = _freshWords();
    }
  }

  @override
  void dispose() {
    for (final c in _words) {
      c.dispose();
    }
    super.dispose();
  }

  bool _answered(int i) => _other[i]
      ? _words[i].text.trim().isNotEmpty
      : _chosen[i].isNotEmpty;

  bool get _complete =>
      [for (var i = 0; i < _chosen.length; i++) _answered(i)].every((a) => a);

  List<RemoteQuestionAnswer> get _answers => [
    for (var i = 0; i < _chosen.length; i++)
      _other[i]
          ? RemoteQuestionAnswer.text(_words[i].text.trim())
          : RemoteQuestionAnswer.options(_chosen[i].toList()..sort()),
  ];

  Future<void> _send({bool decline = false}) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onAnswer(decline ? const [] : _answers, decline: decline);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final questions = widget.question.questions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              AppIcons.warningCircle,
              size: density.iconSmall,
              color: SemanticColors.of(context).attention,
            ),
            SizedBox(width: density.glyphGap),
            Expanded(
              child: Text(
                '${widget.agentName} is asking you'
                '${questions.length == 1 ? ' a question' : ' ${questions.length} questions'}',
                style: theme.textTheme.labelLarge,
              ),
            ),
          ],
        ),
        for (var i = 0; i < questions.length; i++) ...[
          SizedBox(height: density.lineGap * 2),
          _question(context, i),
        ],
        const SizedBox(height: Insets.sm),
        if (!widget.canAnswer)
          Text(
            'This phone was not granted approval rights, so it cannot answer. '
            'Answer on the desktop.',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          )
        else ...[
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.xs,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : () => _send(decline: true),
                child: const Text('Decline'),
              ),
              FilledButton(
                onPressed: _busy || !_complete ? null : _send,
                child: const Text('Send answer'),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Your choice is typed into the session on the desktop.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _question(BuildContext context, int i) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.question.questions[i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.header.isNotEmpty)
          Text(
            item.header.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        Text(item.question, style: theme.textTheme.bodyMedium),
        if (item.multiSelect)
          Text(
            'Choose any.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        for (var o = 0; o < item.options.length; o++)
          CompanionChoice(
            label: item.options[o].label,
            description: item.options[o].description,
            multi: item.multiSelect,
            selected: !_other[i] && _chosen[i].contains(o),
            onTap: _busy || !widget.canAnswer ? null : () => _pick(i, o),
          ),
        // Own words were measured for a single-choice question only.
        if (!item.multiSelect) ...[
          CompanionChoice(
            label: 'Other…',
            description: '',
            multi: false,
            selected: _other[i],
            onTap: _busy || !widget.canAnswer
                ? null
                : () => setState(() {
                    _other[i] = true;
                    _chosen[i] = {};
                  }),
          ),
          if (_other[i])
            Padding(
              padding: const EdgeInsets.only(left: Insets.xl),
              child: TextField(
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
