import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openAutomationsTab;
import '../application/automation_proposals.dart';
import '../application/automation_providers.dart';
import 'webhook_parts.dart' show WebhookSecretDialog;

/// Review, Turn on and Discard for one proposed automation — the same three
/// verbs in the inbox and in the Automations tab.
class ProposalActions extends ConsumerWidget {
  const ProposalActions({required this.automationId, super.key});

  final String automationId;

  void _review(WidgetRef ref) => reviewProposal(ref, automationId);

  Future<void> _turnOn(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final issued = await ref
          .read(automationProposalsProvider)
          .turnOn(automationId);
      if (issued != null && context.mounted) {
        await WebhookSecretDialog.show(context, issued);
      }
    } on StateError catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Not turned on: ${error.message}')),
      );
      _review(ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Wrap(
    spacing: Insets.sm,
    runSpacing: Insets.xs,
    children: [
      TextButton(
        key: ValueKey('proposal-review-$automationId'),
        onPressed: () => _review(ref),
        child: const Text('Review'),
      ),
      FilledButton.tonal(
        key: ValueKey('proposal-on-$automationId'),
        onPressed: () => unawaited(_turnOn(context, ref)),
        child: const Text('Turn on'),
      ),
      TextButton(
        key: ValueKey('proposal-discard-$automationId'),
        onPressed: () =>
            ref.read(automationProposalsProvider).discard(automationId),
        child: const Text('Discard'),
      ),
    ],
  );
}

/// The Automations tab's notice: each automation an agent proposed, waiting
/// for the owner. Nothing in it runs until it is turned on.
class ProposalsNotice extends ConsumerWidget {
  const ProposalsNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proposals = [
      for (final automation in ref.watch(automationsProvider))
        if (automation.isProposed) automation,
    ];
    if (proposals.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final proposal in proposals)
            Card(
              key: ValueKey('proposal-${proposal.id}'),
              margin: const EdgeInsets.only(bottom: Insets.sm),
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(Insets.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          AppIcons.lightning,
                          size: Chrome.iconAction,
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: Insets.sm),
                        Expanded(
                          child: Text(
                            '${proposal.proposedBy} proposed an automation',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Insets.xs),
                    Text(
                      '"${proposal.name}" — ${triggerWords(proposal)}. It does '
                      'nothing until you turn it on.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: Insets.xs),
                    ProposalActions(automationId: proposal.id),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens the Automations tab on [automationId]'s proposal, in the editor.
void reviewProposal(WidgetRef ref, String automationId) {
  openAutomationsTab(ref);
  ref.read(automationProposalsProvider).review(automationId);
}

/// The automation an inbox proposal item is about, or null for any other.
String? proposalOfInboxId(String id) =>
    id.startsWith('proposal:') ? id.substring('proposal:'.length) : null;
