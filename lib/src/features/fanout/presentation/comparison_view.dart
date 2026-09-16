import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/git.dart';
import '../../sessions/application/session_launcher.dart';
import '../../verification/presentation/review_action.dart';
import '../application/comparison_providers.dart';
import '../application/fanout_service.dart';
import '../domain/comparison.dart';
import 'comparison_chrome.dart';

/// One comparison, side by side. Everything drawn comes from the stored
/// [Comparison]; the live handles only decide which *actions* are offered.
class ComparisonView extends ConsumerStatefulWidget {
  const ComparisonView({
    required this.comparisonId,
    required this.onBack,
    super.key,
  });

  final String comparisonId;
  final VoidCallback onBack;

  @override
  ConsumerState<ComparisonView> createState() => _ComparisonViewState();
}

class _ComparisonViewState extends ConsumerState<ComparisonView> {
  /// Diff text per candidate id, fetched on demand and kept while the view is
  /// open. Not stored: the diff *stat* is the durable part.
  final _diffs = <String, Future<String>>{};
  String? _busy;

  @override
  Widget build(BuildContext context) {
    final comparison = ref.watch(comparisonProvider(widget.comparisonId));
    if (comparison == null) {
      return Center(
        child: TextButton(
          onPressed: widget.onBack,
          child: const Text('This comparison is gone. Back to the list.'),
        ),
      );
    }
    final results = {
      for (final result
          in ref.read(fanOutServiceProvider).resultsFor(comparison))
        result.candidate!.id: result,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(comparison),
        const Divider(height: Insets.lg),
        Expanded(
          child: comparison.candidates.isEmpty
              ? const Center(child: Text('No candidates were recorded.'))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final width = candidateColumnWidth(
                      constraints.maxWidth,
                      comparison.candidates.length,
                    );
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final candidate in comparison.candidates) ...[
                            if (candidate.position > 0)
                              const VerticalDivider(width: Insets.lg),
                            SizedBox(
                              width: width,
                              child: _CandidateColumn(
                                comparison: comparison,
                                candidate: candidate,
                                result: results[candidate.id],
                                diff: _diffs[candidate.id],
                                busy: _busy == candidate.id,
                                onRefresh: () => _refresh(candidate, results),
                                onOpenSession: () => _openSession(candidate),
                                onMarkWinner: () =>
                                    _markWinner(candidate, results),
                                onMerge: () => _merge(candidate, results),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
        const Divider(height: Insets.lg),
        _footer(comparison, results),
      ],
    );
  }

  Widget _header(Comparison comparison) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          tooltip: 'All comparisons',
          onPressed: widget.onBack,
          icon: const Icon(AppIcons.arrowLeft, size: Chrome.icon),
        ),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                comparison.prompt,
                maxLines: 3,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: Insets.xs),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '${comparison.candidates.length} agents  ·  '
                      '${shortAge(comparison.createdAt)}',
                      style: theme.textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                  OutcomeLabel(comparison: comparison),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _footer(Comparison comparison, Map<String, FanOutResult> results) {
    final winner = comparison.winner;
    final canDiscard =
        winner != null &&
        results[winner.id] != null &&
        comparison.candidates.any(
          (c) => c.id != winner.id && c.hasLiveWorktree,
        );
    return Row(
      children: [
        // Expanded rather than Text-plus-Spacer, so the two actions keep their
        // width when the window is narrow instead of being pushed off it.
        Expanded(
          child: Text(
            winner == null
                ? 'Pick a winner to merge it and clear the rest.'
                : 'Winner: ${winner.agentId}',
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton.icon(
          onPressed: canDiscard
              ? () => _discardLosers(comparison, results)
              : null,
          icon: const Icon(AppIcons.trash, size: Chrome.iconSmall),
          label: const Text('Discard losing worktrees'),
        ),
        const SizedBox(width: Insets.sm),
        TextButton(
          onPressed: () {
            ref
                .read(comparisonsProvider.notifier)
                .archive(comparison.id, archived: !comparison.archived);
            widget.onBack();
          },
          child: Text(comparison.archived ? 'Unarchive' : 'Archive'),
        ),
      ],
    );
  }

  Future<void> _refresh(
    ComparisonCandidate candidate,
    Map<String, FanOutResult> results,
  ) async {
    final result = results[candidate.id];
    if (result == null) return;
    setState(() {
      _diffs[candidate.id] = ref.read(fanOutServiceProvider).diff(result);
    });
    // Awaited so the recorded stat is on screen before the spinner leaves.
    await _diffs[candidate.id];
  }

  void _openSession(ComparisonCandidate candidate) {
    final sessionId = candidate.sessionId;
    if (sessionId == null) return;
    final revealed = ref.read(sessionLauncherProvider).reveal(sessionId);
    if (!revealed) {
      _say('That session is not running any more.');
      return;
    }
    Navigator.of(context).pop();
  }

  void _markWinner(
    ComparisonCandidate candidate,
    Map<String, FanOutResult> results,
  ) {
    final result = results[candidate.id];
    if (result == null) return;
    ref.read(fanOutServiceProvider).markWinner(result);
  }

  Future<void> _merge(
    ComparisonCandidate candidate,
    Map<String, FanOutResult> results,
  ) async {
    final result = results[candidate.id];
    if (result == null) return;
    // The merge is the moment a verdict is acted on, so it is the moment worth
    // naming the verifier. Said, never enforced — a refusal would hide the fact.
    final confirmed = await _confirm(
      title: 'Merge ${candidate.agentId}?',
      body:
          'Its worktree must be clean and its work committed. '
          '${candidate.branch ?? 'The session branch'} will be merged into the '
          'repository’s current branch.\n\n'
          'Verdict: '
          '${attributionShownFor(candidate, ref.read(candidateEvidenceProvider)).label}.',
      action: 'Merge winner',
    );
    if (confirmed != true) return;
    setState(() => _busy = candidate.id);
    try {
      await ref.read(fanOutServiceProvider).mergeWinner(result);
      _say('${candidate.agentId} merged.');
    } on Object catch (error) {
      _say('$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Discard, then ask about exactly what it refused to delete: the service
  /// keeps a dirty worktree unless the caller names that session.
  Future<void> _discardLosers(
    Comparison comparison,
    Map<String, FanOutResult> results,
  ) async {
    final winner = comparison.winner;
    final winnerResult = winner == null ? null : results[winner.id];
    if (winnerResult == null) return;
    final all = comparison.candidates
        .map((c) => results[c.id])
        .nonNulls
        .toList();

    setState(() => _busy = winner!.id);
    var discard = await ref
        .read(fanOutServiceProvider)
        .discardLosers(all, winner: winnerResult);
    if (!mounted) return;

    final dirty = discard.kept
        .where((k) => k.reason == FanOutKeepReason.uncommittedChanges)
        .toList();
    if (dirty.isNotEmpty) {
      final confirmed = await _confirmDirty(dirty);
      if (confirmed.isNotEmpty && mounted) {
        discard = await ref
            .read(fanOutServiceProvider)
            .discardLosers(
              all,
              winner: winnerResult,
              discardUncommittedFor: confirmed,
            );
      }
    }
    if (!mounted) return;
    setState(() => _busy = null);

    final running = discard.kept
        .where((k) => k.reason == FanOutKeepReason.stillRunning)
        .map((k) => k.result.agentId);
    _say(
      [
        '${discard.removed.length} worktree'
            '${discard.removed.length == 1 ? '' : 's'} removed.',
        if (running.isNotEmpty) 'Still running: ${running.join(', ')}.',
        for (final failure in discard.failures)
          '${failure.agentId}: ${failure.error}',
      ].join(' '),
    );
  }

  Future<Set<String>> _confirmDirty(List<FanOutKept> dirty) async {
    final chosen = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: const Text('These worktrees hold uncommitted work'),
          content: BoundedDialogContent(
            width: DialogWidth.regular,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nothing here is on a branch. Removing it destroys the only '
                  'copy. Tick the ones that may go.',
                ),
                const SizedBox(height: Insets.sm),
                for (final kept in dirty)
                  CheckboxListTile(
                    dense: true,
                    value: chosen.contains(kept.result.session.id),
                    title: Text(kept.result.agentId),
                    subtitle: Text(
                      kept.changes.map((c) => c.path).join(', '),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: MonoStyles.body,
                    ),
                    onChanged: (value) => setInner(() {
                      if (value ?? false) {
                        chosen.add(kept.result.session.id);
                      } else {
                        chosen.remove(kept.result.session.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep them all'),
            ),
            DestructiveButton(
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text('Delete ${chosen.length}'),
            ),
          ],
        ),
      ),
    );
    return ok == true ? chosen : const {};
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String action,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Candidates share the width they are given, never narrower than
/// [minCandidateColumnWidth]; past that the row scrolls sideways.
const minCandidateColumnWidth = 300.0;

double candidateColumnWidth(double available, int candidates) {
  if (candidates <= 0) return minCandidateColumnWidth;
  final dividers = Insets.lg * (candidates - 1);
  final share = (available - dividers) / candidates;
  return share < minCandidateColumnWidth ? minCandidateColumnWidth : share;
}

class _CandidateColumn extends ConsumerWidget {
  const _CandidateColumn({
    required this.comparison,
    required this.candidate,
    required this.result,
    required this.diff,
    required this.busy,
    required this.onRefresh,
    required this.onOpenSession,
    required this.onMarkWinner,
    required this.onMerge,
  });

  final Comparison comparison;
  final ComparisonCandidate candidate;

  /// The live handle, or `null` when nothing is left to act on.
  final FanOutResult? result;
  final Future<String>? diff;
  final bool busy;
  final VoidCallback onRefresh;
  final VoidCallback onOpenSession;
  final VoidCallback onMarkWinner;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isWinner = comparison.winnerCandidateId == candidate.id;
    final evidence = evidenceShownFor(
      candidate,
      ref.watch(candidateEvidenceProvider),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Capped and scrolling: in a 300px column at 1.3x text the actions
            // wrap to three rows, and the diff below must keep a share.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.6,
              ),
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        CandidateStateMark(
                          candidate: candidate,
                          isWinner: isWinner,
                        ),
                        const SizedBox(width: Insets.sm),
                        Expanded(
                          child: Text(
                            candidate.agentId,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Re-read the diff',
                          visualDensity: VisualDensity.compact,
                          onPressed: candidate.hasLiveWorktree && result != null
                              ? onRefresh
                              : null,
                          icon: const Icon(
                            AppIcons.arrowsClockwise,
                            size: Chrome.icon,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      candidate.branch ?? 'no branch',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: kMonoFamily,
                      ),
                    ),
                    const SizedBox(height: Insets.xs),
                    DiffStatLine(stat: candidate.diff),
                    if (evidence != null) ...[
                      const SizedBox(height: Insets.xs),
                      VerdictChip(
                        evidence: evidence,
                        attribution: evidence.attributionFor(
                          candidate.sessionId,
                        ),
                      ),
                    ],
                    const SizedBox(height: Insets.xs),
                    _state(context),
                    const SizedBox(height: Insets.sm),
                    _actions(context),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Insets.sm),
            Expanded(child: _diffBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _state(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    if (!candidate.started) {
      return Text(
        candidate.failure ?? 'never started',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(color: semantic.failure),
      );
    }
    if (candidate.worktreeRemoved) {
      return Text(
        'worktree removed  ·  branch kept',
        style: theme.textTheme.labelSmall?.copyWith(color: semantic.neutral),
      );
    }
    return Text(
      candidate.worktree?.path ?? 'no worktree',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(fontFamily: kMonoFamily),
    );
  }

  Widget _actions(BuildContext context) {
    final live = result != null && candidate.hasLiveWorktree;
    return Wrap(
      spacing: Insets.xs,
      runSpacing: Insets.xs,
      children: [
        OutlinedButton.icon(
          onPressed: candidate.sessionId == null ? null : onOpenSession,
          icon: const Icon(AppIcons.terminal, size: Chrome.iconSmall),
          label: const Text('Open'),
        ),
        // N agents answer, and one of them checks another. The comparison's own
        // prompt is the claim being checked, in the words every candidate was asked in.
        if (candidate.sessionId case final sessionId?)
          ReviewAction(
            sessionId: sessionId,
            claim: comparison.prompt,
            compact: true,
          ),
        OutlinedButton.icon(
          onPressed: live && !busy ? onMarkWinner : null,
          icon: const Icon(AppIcons.star, size: Chrome.iconSmall),
          label: const Text('Winner'),
        ),
        FilledButton.icon(
          onPressed: live && !busy ? onMerge : null,
          icon: const Icon(AppIcons.gitMerge, size: Chrome.iconSmall),
          label: Text(busy ? 'Merging…' : 'Merge'),
        ),
      ],
    );
  }

  Widget _diffBody(BuildContext context) {
    if (!candidate.hasLiveWorktree) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          candidate.started
              ? 'The worktree is gone. The stat above is what it last showed.'
              : 'Nothing ran, so there is nothing to diff.',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      );
    }
    if (diff == null) {
      return Align(
        alignment: Alignment.topLeft,
        child: TextButton.icon(
          onPressed: result == null ? null : onRefresh,
          icon: const Icon(AppIcons.gitDiff, size: Chrome.iconSmall),
          label: const Text('Read the diff'),
        ),
      );
    }
    return FutureBuilder<String>(
      future: diff,
      builder: (context, snapshot) => SingleChildScrollView(
        child: SelectableText(
          snapshot.connectionState != ConnectionState.done
              ? 'Reading…'
              : snapshot.hasError
              ? '${snapshot.error}'
              : snapshot.data!.trim().isEmpty
              ? 'Nothing uncommitted. Committed work shows as a commit count '
                    'above.'
              // Where the tiering earns most: four columns are drawn side by
              // side, and git's alphabetical order opens all four on
              // `pubspec.lock`. Reordered, never trimmed.
              : orderUnifiedDiffForReview(snapshot.data!),
          style: MonoStyles.small,
        ),
      ),
    );
  }
}
