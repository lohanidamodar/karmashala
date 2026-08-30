import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../client/companion_gateway.dart';

/// The pending approval for one session, on the phone.
///
/// Drawn to the desktop card's rules (Loop 49), which are not stylistic:
///
/// * **evidence is verbatim or absent** — the agent's own rows, monospaced,
///   scrolling rather than re-flowing, never a summary in our words;
/// * **only answers the agent named** get buttons, and every button says which
///   keys it presses on the user's behalf;
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
  bool _busy = false;

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
    final approval = widget.approval;

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(AppIcons.warningCircle, size: 14, color: scheme.tertiary),
              const SizedBox(width: Insets.xs),
              Expanded(
                child: Text(
                  '${approval.agentName} is waiting for you',
                  style: theme.textTheme.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          _evidence(theme, scheme),
          const SizedBox(height: Insets.sm),
          _answers(theme, scheme),
        ],
      ),
    );
  }

  /// What the agent said, quoted, or an admission that we do not know.
  Widget _evidence(ThemeData theme, ColorScheme scheme) {
    final approval = widget.approval;
    if (approval.evidence.isEmpty) {
      return Text(
        'We can tell ${approval.agentName} is asking for something, but not '
        'what. Open the session on the desktop to read the prompt.',
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
        const SizedBox(height: 2),
        // Scrolls rather than wrapping: these are rendered terminal rows and
        // re-flowing them would break the alignment they were drawn with.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 132),
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

  /// The buttons, and the sentence explaining any that are missing.
  Widget _answers(ThemeData theme, ColorScheme scheme) {
    final approval = widget.approval;
    if (!widget.canAnswer) {
      return Text(
        'This phone was not granted approval rights, so it cannot answer. '
        'Answer on the desktop.',
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
      );
    }

    final hasApprove = approval.approveLabel != null;
    final hasDeny = approval.denyLabel != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasApprove || hasDeny)
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
        const SizedBox(height: 2),
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
        if (!hasApprove && !hasDeny)
          Text(
            '${approval.agentName} has not told us which keys answer its '
            'prompts, so answer it on the desktop.',
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
          )
        else if (!hasDeny)
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
