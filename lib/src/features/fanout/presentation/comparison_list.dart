import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../repositories/application/repository_providers.dart';
import '../application/comparison_providers.dart';
import '../domain/comparison.dart';
import 'comparison_chrome.dart';

/// Every fan-out that has been run, newest first. Before it a comparison
/// existed only while its dialog was open.
class ComparisonList extends ConsumerWidget {
  const ComparisonList({required this.onOpen, required this.onNew, super.key});

  final void Function(String comparisonId) onOpen;
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final comparisons = ref.watch(comparisonsProvider);
    final controller = ref.watch(comparisonsProvider.notifier);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // Expanded, not a bare Text plus Spacer: at 720x560 the dialog is
            // only 664 wide and the title used to hold its full intrinsic
            // width, pushing "New fan-out" past the window edge.
            Expanded(
              child: Text(
                'Fan-out comparisons',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () =>
                  controller.showArchived(!controller.includeArchived),
              child: Text(
                controller.includeArchived ? 'Hide archived' : 'Show archived',
              ),
            ),
            const SizedBox(width: Insets.sm),
            FilledButton.icon(
              onPressed: onNew,
              icon: const Icon(AppIcons.plus, size: Chrome.iconSmall),
              label: const Text('New fan-out'),
            ),
          ],
        ),
        const Divider(height: Insets.lg),
        Expanded(
          child: comparisons.isEmpty
              ? Center(
                  child: Text(
                    onNew == null
                        ? 'Select a repository to start a fan-out.'
                        : 'No comparisons yet. Run one prompt on several '
                              'agents and they collect here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView.separated(
                  itemCount: comparisons.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _ComparisonRow(
                    comparison: comparisons[index],
                    onOpen: () => onOpen(comparisons[index].id),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ComparisonRow extends ConsumerWidget {
  const _ComparisonRow({required this.comparison, required this.onOpen});

  final Comparison comparison;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repository = ref
        .read(repositoryDaoProvider)
        .getById(comparison.repositoryId);
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.sm,
          vertical: Insets.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    comparison.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: Insets.sm),
                OutcomeLabel(comparison: comparison),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Wrap(
              spacing: Insets.md,
              runSpacing: Insets.xs,
              children: [
                for (final candidate in comparison.candidates)
                  _CandidateChip(
                    candidate: candidate,
                    isWinner: comparison.winnerCandidateId == candidate.id,
                  ),
              ],
            ),
            const SizedBox(height: Insets.xs),
            Text(
              [
                if (repository != null) repository.name,
                shortAge(comparison.createdAt),
                if (comparison.archived) 'archived',
              ].join('  ·  '),
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateChip extends StatelessWidget {
  const _CandidateChip({required this.candidate, required this.isWinner});

  final ComparisonCandidate candidate;
  final bool isWinner;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CandidateStateMark(candidate: candidate, isWinner: isWinner),
        const SizedBox(width: Insets.xs),
        Text(
          candidate.agentId,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(fontFamily: kMonoFamily),
        ),
        const SizedBox(width: Insets.xs),
        DiffStatLine(stat: candidate.diff, dense: true),
      ],
    );
  }
}
