import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../verification/domain/verdict_attribution.dart';
import '../../verification/presentation/attribution_mark.dart';
import '../application/comparison_providers.dart';
import '../domain/comparison.dart';

/// Small shared pieces of the comparison surface. Neutral by decision: the
/// only colour is [SemanticColors] — diff add/remove, a failure, a verdict.

/// What state a candidate is in — as a glyph and a word, then a colour. State
/// is never carried by colour alone; a bare dot told a screen reader nothing.
class CandidateStateMark extends StatelessWidget {
  const CandidateStateMark({
    required this.candidate,
    this.isWinner = false,
    super.key,
  });

  final ComparisonCandidate candidate;
  final bool isWinner;

  /// Decided in this order, and the order is the point: a winner's worktree is
  /// usually gone by the time it is one, and "winner" is the more useful fact.
  CandidateState get state {
    if (!candidate.started) return CandidateState.didNotStart;
    if (isWinner) return CandidateState.winner;
    if (candidate.worktreeRemoved) return CandidateState.worktreeRemoved;
    return CandidateState.started;
  }

  static IconData _glyphOf(CandidateState state) => switch (state) {
    CandidateState.didNotStart => AppIcons.warningCircle,
    // The same glyph the "Winner" action carries, so pressing it and reading
    // the result are the same picture.
    CandidateState.winner => AppIcons.star,
    CandidateState.worktreeRemoved => AppIcons.minusCircle,
    CandidateState.started => AppIcons.circleHalf,
  };

  static Color _colourOf(SemanticColors semantic, CandidateState state) =>
      switch (state) {
        CandidateState.didNotStart => semantic.failure,
        CandidateState.winner => semantic.idle,
        CandidateState.worktreeRemoved => semantic.neutral,
        CandidateState.started => semantic.working,
      };

  String get _tooltip {
    final failure = candidate.failure?.trim();
    return switch (state) {
      CandidateState.didNotStart =>
        failure == null || failure.isEmpty
            ? 'Did not start — this agent never got a worktree.'
            : 'Did not start. $failure',
      CandidateState.winner =>
        'Winner — the candidate this comparison settled on.',
      CandidateState.worktreeRemoved =>
        'Worktree removed. The record stays; there is nothing left to diff.',
      CandidateState.started => 'Started, and its worktree is still on disk.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final current = state;
    return Tooltip(
      message: _tooltip,
      child: Icon(
        _glyphOf(current),
        size: Chrome.iconSmall,
        color: _colourOf(SemanticColors.of(context), current),
        semanticLabel: current.label,
      ),
    );
  }
}

/// The four things a candidate can be, in the words a reader sees: "did not
/// start", not "failed"; "started", not "running", which nothing here can see.
enum CandidateState {
  didNotStart('Did not start'),
  winner('Winner'),
  worktreeRemoved('Worktree removed'),
  started('Started');

  const CandidateState(this.label);

  final String label;
}

/// `3 files +42 −7 · 2 commits`, with the two numbers that mean something
/// coloured and the rest on the ramp.
class DiffStatLine extends StatelessWidget {
  const DiffStatLine({required this.stat, this.dense = false, super.key});

  final CandidateDiffStat? stat;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final base =
        (dense ? theme.textTheme.labelSmall : theme.textTheme.bodySmall)
            ?.copyWith(fontFamily: kMonoFamily);
    final value = stat;
    if (value == null) {
      return Text(
        'not read yet',
        style: base?.copyWith(color: semantic.neutral),
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          if (value.filesChanged > 0)
            TextSpan(
              text:
                  '${value.filesChanged} '
                  'file${value.filesChanged == 1 ? '' : 's'}  ',
            ),
          if (value.insertions > 0 || value.deletions > 0) ...[
            TextSpan(
              text: '+${value.insertions}',
              style: TextStyle(color: semantic.diffAdded),
            ),
            const TextSpan(text: ' '),
            TextSpan(
              text: '−${value.deletions}',
              style: TextStyle(color: semantic.diffRemoved),
            ),
          ],
          if ((value.commits ?? 0) > 0)
            TextSpan(
              text:
                  '  · ${value.commits} '
                  'commit${value.commits == 1 ? '' : 's'}',
            ),
          if (value.isEmpty && value.insertions == 0 && value.deletions == 0)
            TextSpan(
              text: 'no changes',
              style: TextStyle(color: semantic.neutral),
            ),
        ],
      ),
      style: base,
    );
  }
}

/// A verification verdict beside the diff stat. [attribution] is required, not
/// optional: an optional parameter is how a caller quietly stops saying.
class VerdictChip extends StatelessWidget {
  const VerdictChip({
    required this.evidence,
    required this.attribution,
    super.key,
  });

  final CandidateEvidence evidence;
  final VerdictAttribution attribution;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final (color, icon) = switch (evidence.verdict) {
      EvidenceVerdict.passed => (semantic.idle, AppIcons.checkCircle),
      EvidenceVerdict.failed => (semantic.failure, AppIcons.xCircle),
      EvidenceVerdict.inconclusive => (semantic.neutral, AppIcons.question),
    };
    final labelStyle = Theme.of(context).textTheme.labelSmall;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: Chrome.iconSmall, color: color),
        const SizedBox(width: Insets.xs),
        Flexible(
          child: Text(
            evidence.label ?? evidence.verdict.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelStyle?.copyWith(color: color),
          ),
        ),
        const SizedBox(width: Insets.xs),
        AttributionMark(attribution: attribution),
      ],
    );
  }
}

/// The comparison's own state, as one word on the ramp — and who graded the
/// candidate it settled on.
class OutcomeLabel extends ConsumerWidget {
  const OutcomeLabel({required this.comparison, super.key});

  final Comparison comparison;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final semantic = SemanticColors.of(context);
    final theme = Theme.of(context);
    final (text, color) = switch (comparison.outcome) {
      ComparisonOutcome.merged => (
        ['merged', ?comparison.shortMergedCommit].join(' '),
        semantic.idle,
      ),
      ComparisonOutcome.discarded => ('discarded', semantic.neutral),
      ComparisonOutcome.pending => (
        comparison.winnerCandidateId == null ? 'open' : 'winner chosen',
        semantic.attention,
      ),
    };
    // Who graded the winner, on the outcome itself — the list shows no candidate
    // chip. Resolved live through the same helper, so the two cannot disagree.
    final winner = comparison.winner;
    final attribution = winner == null
        ? null
        : attributionShownFor(winner, ref.watch(candidateEvidenceProvider));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontFamily: kMonoFamily,
          ),
        ),
        if (attribution != null) ...[
          const SizedBox(width: Insets.xs),
          AttributionMark(attribution: attribution),
        ],
      ],
    );
  }
}

/// `4m`, `3h`, `2d` — a age, not a date. Comparisons are read in the days after
/// they run, and a full timestamp in a dense row is noise.
String shortAge(DateTime when, {DateTime? now}) {
  final delta = (now ?? DateTime.now().toUtc()).difference(when.toUtc());
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays < 30) return '${delta.inDays}d ago';
  return '${when.toLocal().year}-'
      '${when.toLocal().month.toString().padLeft(2, '0')}-'
      '${when.toLocal().day.toString().padLeft(2, '0')}';
}
