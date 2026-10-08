import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../application/automation_proposals.dart';
import '../application/automation_providers.dart';
import '../application/turn_on_review.dart';
import 'proposal_actions.dart' show reviewProposal;
import 'webhook_parts.dart' show WebhookSecretDialog;

/// Asks before [automation] is turned on, when it would act unattended or an
/// agent proposed it. True when it may be turned on; false for Cancel or a
/// dismissal. [proposedBy] is for a copy rebuilt from the editor's draft.
Future<bool> confirmTurnOn(
  BuildContext context,
  WidgetRef ref,
  Automation automation, {
  String? proposedBy,
}) async {
  if (!turnOnNeedsConfirm(automation) && proposedBy == null) return true;
  final repository = ref
      .read(automationCheckoutsProvider)
      .where((r) => r.id == automation.repositoryId)
      .firstOrNull;
  final registry = ref.read(agentRegistryProvider);
  final installation = ref
      .read(agentInstallationsDataProvider)
      .getById(automation.agentInstallationId);
  final descriptor = installation == null
      ? null
      : registry.byId(installation.agentId);
  final review = turnOnReview(
    automation,
    checkout: repository?.name ?? 'its checkout',
    agent: descriptor?.displayName ?? 'the agent',
    permissions: descriptor?.launch.permission,
    proposedBy: proposedBy,
    now: ref.read(clockProvider).nowUtc(),
  );
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => TurnOnConfirmDialog(review: review),
  );
  return confirmed ?? false;
}

/// Turns [automation] on once confirmed: a proposal through
/// [AutomationProposals.turnOn], which arms it and issues a webhook's secret;
/// anything else by its switch.
Future<void> turnOnAutomation(
  BuildContext context,
  WidgetRef ref,
  Automation automation,
) async {
  if (!await confirmTurnOn(context, ref, automation)) return;
  if (!context.mounted) return;
  if (!automation.isProposed) {
    ref
        .read(automationControllerProvider)
        .setEnabled(automation.id, enabled: true);
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final issued = await ref
        .read(automationProposalsProvider)
        .turnOn(automation.id);
    if (issued != null && context.mounted) {
      await WebhookSecretDialog.show(context, issued);
    }
  } on StateError catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Not turned on: ${error.message}')),
    );
    reviewProposal(ref, automation.id);
  }
}

/// What turning one automation on lets it do, and its limits; a proposal adds
/// who proposed it and every step in full.
class TurnOnConfirmDialog extends StatelessWidget {
  const TurnOnConfirmDialog({required this.review, super.key});

  final TurnOnReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final proposer = review.proposedBy;
    return AlertDialog(
      key: const ValueKey('turn-on-confirm'),
      title: DesktopDialogTitle(
        icon: AppIcons.lightning,
        title: 'Turn on "${review.name}"?',
        subtitle: 'Once on, it runs with nobody watching.',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              review.summary,
              key: const ValueKey('turn-on-summary'),
              style: theme.textTheme.bodyMedium,
            ),
            if (proposer != null) ...[
              const SizedBox(height: Insets.md),
              Container(
                key: const ValueKey('turn-on-proposer'),
                padding: const EdgeInsets.all(Insets.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Text(
                  'Proposed by $proposer. An agent wrote it: read every step '
                  'before turning it on.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
            const SizedBox(height: Insets.lg),
            const EyebrowLabel('What it can change'),
            const SizedBox(height: Insets.xs),
            for (final line in review.changes) _Line(line: line, muted: muted),
            const SizedBox(height: Insets.md),
            const EyebrowLabel('Its limits'),
            const SizedBox(height: Insets.xs),
            for (final line in review.limits) _Line(line: line, muted: muted),
            if (review.steps.isNotEmpty) ...[
              const SizedBox(height: Insets.md),
              const EyebrowLabel('Every step'),
              const SizedBox(height: Insets.xs),
              for (final (index, step) in review.steps.indexed)
                _Line(
                  key: ValueKey('turn-on-step-${step.key}'),
                  line: (
                    label: '${index + 1}. ${step.title}',
                    text: step.would,
                  ),
                  muted: muted,
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('turn-on-cancel'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('turn-on-confirm-button'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Turn on'),
        ),
      ],
    );
  }
}

/// A label over its text, so a long label never squeezes the text at a phone
/// width or large type.
class _Line extends StatelessWidget {
  const _Line({required this.line, required this.muted, super.key});

  final TurnOnLine line;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Insets.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line.label, style: muted),
        const SizedBox(height: Insets.xxs),
        SelectableText(
          line.text,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    ),
  );
}
