import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../remote/domain/remote_payloads.dart';
import '../client/companion_gateway.dart';

/// The pending approval for one session, on the phone.
///
/// Drawn to the desktop card's rules (Loop 49), which are not stylistic:
///
/// * **evidence is verbatim or absent** — the agent's own rows, monospaced,
///   scrolling rather than re-flowing, never a summary in our words;
/// * **only answers the agent named** get buttons, and every button says which
///   keys it presses on the user's behalf;
/// * **buttons only when a prompt is open.** `needs_approval` means the session
///   has stopped for the user; it does not mean there is something to confirm.
///   Claude Code fires the same hook when it has merely finished its turn, and
///   approve types Enter — which at that prompt sends whatever is in the
///   composer. So [RemoteWaitKind.input] gets the same card with the same
///   quoted words and nothing to press, exactly as `ApprovalRequestCard` does
///   on the desktop;
/// * pinned above the composer, because it is a control over the session, not
///   a message in it.
class CompanionApprovalCard extends StatefulWidget {
  const CompanionApprovalCard({
    required this.approval,
    required this.onAnswer,
    this.canAnswer = true,
    super.key,
  });

  final CompanionApproval approval;

  /// Sends the decision to the host; awaited for a busy state.
  final Future<void> Function(CompanionApprovalDecision decision) onAnswer;

  /// Whether this phone holds the `approve` capability.
  final bool canAnswer;

  @override
  State<CompanionApprovalCard> createState() => _CompanionApprovalCardState();
}

class _CompanionApprovalCardState extends State<CompanionApprovalCard> {
  /// How many rows of the agent's own output the quote box shows before it
  /// scrolls. Expressed in rows rather than pixels so a reader at 200% text
  /// gets the same eight rows a reader at 100% does, instead of three.
  static const _evidenceRows = 8;

  bool _busy = false;

  /// Whether this card may offer keys at all.
  ///
  /// The host decides, and now says so twice: it names an answer only for a
  /// prompt it can see, and it says what the session is waiting on. A label
  /// from a host too old to send [RemoteWaitKind] is still honoured — that end
  /// can make no other claim — but [RemoteWaitKind.input] is refused whatever
  /// arrives with it, because the session it describes is sitting at its own
  /// composer and approve would type into that.
  bool get _answerable =>
      widget.approval.waiting != RemoteWaitKind.input &&
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

    return Container(
      // Lined up with the transcript above it rather than on a gutter of its
      // own: it was inset 8 while the messages it is about were inset 12 and
      // the composer under it 16, so three stacked things had three edges.
      margin: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.md, Insets.sm),
      padding: EdgeInsets.symmetric(
        horizontal: density.padX,
        vertical: density.padY,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        // The radius every other card on the phone draws; Radii.sm is the
        // desktop's, and a 6px corner on a full-width card reads as an
        // accident rather than as a decision.
        borderRadius: BorderRadius.circular(
          density.isTouch ? Radii.lg : Radii.sm,
        ),
        border: Border.all(color: scheme.outlineVariant),
      ),
      // The card grows with the text scale and the footer it sits in does not
      // scroll, so at a large scale it would push the conversation off the
      // screen. Capped against the viewport and scrolled inside instead: a
      // card that has to be scrolled still shows every word, and a clipped one
      // hides the evidence the reader is being asked to act on.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.45,
        ),
        child: SingleChildScrollView(
          child: Column(
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
                    // Being asked for something is the semantic layer's
                    // `attention`, not the scheme's tertiary — a colour that
                    // means nothing anywhere else in the app. A card with
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
              // phone may press it: "you were not granted approval rights"
              // would be a strange thing to tell someone about a session that
              // has nothing to approve.
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
      ),
    );
  }

  /// What the agent said, quoted, or an admission that we do not know.
  Widget _evidence(BuildContext context, ThemeData theme, ColorScheme scheme) {
    final approval = widget.approval;
    final name = approval.agentName;
    if (approval.evidence.isEmpty) {
      // What it can honestly say depends on what the session is waiting on:
      // "asking for something" is a claim, and it is false for an agent that
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
        // Scrolls rather than wrapping: these are rendered terminal rows and
        // re-flowing them would break the alignment they were drawn with.
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
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// [_evidenceRows] rows of the quote box, at whatever size the reader's own
  /// text scale makes a row. A fixed pixel cap shrank the evidence to three
  /// lines exactly when the reader had asked for bigger text.
  double _evidenceHeight(BuildContext context, ThemeData theme) {
    final style = theme.textTheme.bodySmall;
    final row = (style?.fontSize ?? Insets.md) * (style?.height ?? 1.35);
    return MediaQuery.textScalerOf(context).scale(row) * _evidenceRows;
  }

  /// The notice for a session that has stopped for the user with no prompt we
  /// may answer. Deliberately has no buttons at all rather than disabled ones.
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
        // Every button says what it does on the user's behalf: the desktop is
        // typing into another program's interface for you.
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
