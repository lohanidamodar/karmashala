import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';
import 'companion_question_card.dart';

/// The pending approval for one session, evidence verbatim. Nothing to press
/// for [RemoteWaitKind.input] — there approve would type Enter into a composer.
class CompanionApprovalCard extends StatefulWidget {
  const CompanionApprovalCard({
    required this.approval,
    required this.onAnswer,
    this.onAnswerQuestion,
    this.canAnswer = true,
    super.key,
  });

  /// Answers a multiple-choice question; null where none can be answered.

  final CompanionApproval approval;

  /// Sends the decision to the host; awaited for a busy state.
  final Future<void> Function(CompanionApprovalDecision decision) onAnswer;

  final CompanionQuestionAnswerFn? onAnswerQuestion;

  /// Whether this phone holds the `approve` capability.
  final bool canAnswer;

  @override
  State<CompanionApprovalCard> createState() => _CompanionApprovalCardState();
}

class _CompanionApprovalCardState extends State<CompanionApprovalCard> {
  /// How many rows of the agent's own output the quote box shows before it
  /// scrolls. Rows and not pixels, so 200% text still gets eight of them.
  static const _evidenceRows = 8;

  bool _busy = false;

  /// Whether this card may offer keys at all. The host decides; a label from a
  /// host too old to send [RemoteWaitKind] is still honoured, but
  /// [RemoteWaitKind.input] is refused whatever arrives with it.
  bool get _answerable =>
      widget.approval.waiting != RemoteWaitKind.input &&
      widget.approval.waiting != RemoteWaitKind.question &&
      (widget.approval.approveLabel != null ||
          widget.approval.denyLabel != null);

  Future<void> _answer(CompanionApprovalDecision decision) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await widget.onAnswer(decision);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is GatewayException ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    final approval = widget.approval;
    final name = approval.agentName;
    final question = approval.question;
    final onQuestion = widget.onAnswerQuestion;

    return Container(
      // Lined up with the transcript above it; three stacked things had three
      // different edges.
      margin: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.sm),
      padding: EdgeInsets.symmetric(
        horizontal: density.padX,
        vertical: density.padY,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        // The radius every other card on the phone draws; Radii.sm is the
        // desktop's and reads as an accident at full width.
        borderRadius: BorderRadius.circular(
          density.isTouch ? Radii.lg : Radii.sm,
        ),
        border: Border.all(color: scheme.outlineVariant),
      ),
      // Bounded by the space it is given, not the window: in the session
      // footer that is already a scroll, and a height it was never given
      // pushed the composer under the keyboard.
      child: SingleChildScrollView(
        primary: false,
        child: question != null && onQuestion != null
            ? CompanionQuestionCard(
                agentName: name,
                question: question,
                canAnswer: widget.canAnswer,
                onAnswer: onQuestion,
              )
            : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  _answerable
                      ? AppIcons.warningCircle
                      : AppIcons.chatCircleDots,
                  size: density.iconSmall,
                  // Being asked for something is `attention`; a card with
                  // nothing to press is not asking, so it stays muted.
                  color: _answerable
                      ? SemanticColors.of(context).attention
                      : scheme.onSurfaceVariant,
                ),
                SizedBox(width: density.glyphGap),
                Expanded(
                  child: Text(switch (approval.waiting) {
                    RemoteWaitKind.input => '$name is waiting for your input',
                    RemoteWaitKind.unrecorded when !_answerable =>
                      '$name needs your attention',
                    _ => '$name is waiting for you',
                  }, style: theme.textTheme.labelLarge),
                ),
              ],
            ),
            SizedBox(height: density.lineGap),
            _evidence(context, theme, scheme),
            const SizedBox(height: Insets.sm),
            // Whether anything can be pressed is asked before whether this
            // phone may press it, or a session with nothing to approve would
            // be answered with "you were not granted approval rights".
            if (!_answerable)
              _nothingToAnswer(theme, scheme)
            else if (!widget.canAnswer)
              Text(
                'This phone was not granted approval rights, so it cannot '
                'answer. Answer on the desktop.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.error,
                ),
              )
            else
              _answers(theme, scheme),
          ],
        ),
      ),
    );
  }

  /// What the agent said, quoted, or an admission that we do not know.
  Widget _evidence(BuildContext context, ThemeData theme, ColorScheme scheme) {
    final approval = widget.approval;
    final name = approval.agentName;
    if (approval.evidence.isEmpty) {
      // "Asking for something" is a claim, and it is false for an agent that
      // has simply finished its turn.
      return Text(
        switch (approval.waiting) {
          RemoteWaitKind.input =>
            '$name has finished its turn and is sitting at its own prompt. '
                'Reply to it below.',
          RemoteWaitKind.unrecorded when !_answerable =>
            'We can tell $name has stopped for you, but not what it wants. '
                'Open the session on the desktop to see what it is showing.',
          _ =>
            'We can tell $name is asking for something, but not what. Open '
                'the session on the desktop to read the prompt.',
        },
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'It says:',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        SizedBox(height: UiDensity.of(context).lineGap),
        // Scrolls rather than wrapping: re-flowing rendered terminal rows would
        // break the alignment they were drawn with.
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: _evidenceHeight(context, theme),
          ),
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                approval.evidence.join('\n'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// [_evidenceRows] rows at whatever size the reader's text scale makes a row;
  /// a fixed pixel cap shrank the evidence exactly when text got bigger.
  double _evidenceHeight(BuildContext context, ThemeData theme) {
    final style = theme.textTheme.bodySmall;
    final row = (style?.fontSize ?? Insets.md) * (style?.height ?? 1.35);
    return MediaQuery.textScalerOf(context).scale(row) * _evidenceRows;
  }

  /// The notice for a session stopped for the user with no prompt we may
  /// answer. No buttons at all, rather than disabled ones.
  Widget _nothingToAnswer(ThemeData theme, ColorScheme scheme) {
    final name = widget.approval.agentName;
    return Text(switch (widget.approval.waiting) {
      RemoteWaitKind.input =>
        'There is nothing to approve — $name is at its own prompt, so reply '
            'to it below.',
      RemoteWaitKind.approval =>
        '$name has not told us which keys answer its prompts, so answer it '
            'on the desktop.',
      RemoteWaitKind.unrecorded =>
        'We cannot tell whether $name has a prompt open, so Karmashala will '
            'not send it a key. Answer on the desktop.',
      RemoteWaitKind.question =>
        '$name is asking a question this phone could not read, so answer '
            'it on the desktop.',
    }, style: theme.textTheme.labelSmall?.copyWith(color: scheme.error));
  }

  /// The buttons, and the sentence explaining any that are missing.
  Widget _answers(ThemeData theme, ColorScheme scheme) {
    final approval = widget.approval;
    final hasApprove = approval.approveLabel != null;
    final hasDeny = approval.denyLabel != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (hasDeny)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _answer(CompanionApprovalDecision.deny),
                child: Text(approval.denyLabel!),
              ),
            if (hasApprove)
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _answer(CompanionApprovalDecision.approve),
                child: Text(approval.approveLabel!),
              ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        // Every button says which keys it presses on the user's behalf.
        for (final (label, effect) in [
          (approval.approveLabel, approval.approveEffect),
          (approval.denyLabel, approval.denyEffect),
        ])
          if (label != null && effect != null)
            Text(
              '$label: $effect',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        if (!hasDeny)
          Text(
            "${approval.agentName}'s prompt names no way to decline. To "
            'refuse, use the desktop.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
