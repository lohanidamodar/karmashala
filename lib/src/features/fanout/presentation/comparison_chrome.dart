import 'package:flutter/material.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../domain/comparison.dart';

/// Small shared pieces of the comparison surface.
///
/// Neutral by decision (`docs/superpowers/specs/2026-08-30-desktop-ui-direction.md`):
/// the ramp carries the chrome and the only colour is [SemanticColors] — diff
/// add/remove, a failed launch, a verdict. Nothing here is branded.

/// A 7px dot in the colour of a candidate's state.
class CandidateDot extends StatelessWidget {
  const CandidateDot({
    required this.candidate,
    this.isWinner = false,
    super.key,
  });

  final ComparisonCandidate candidate;
  final bool isWinner;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final color = switch (candidate) {
      _ when !candidate.started => semantic.failure,
      _ when isWinner => semantic.idle,
      _ when candidate.worktreeRemoved => semantic.neutral,
      _ => semantic.working,
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
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

/// A verification verdict beside the diff stat. Absent when nothing has one.
class VerdictChip extends StatelessWidget {
  const VerdictChip({required this.evidence, super.key});

  final CandidateEvidence evidence;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    final (color, icon) = switch (evidence.verdict) {
      EvidenceVerdict.passed => (semantic.idle, AppIcons.checkCircle),
      EvidenceVerdict.failed => (semantic.failure, AppIcons.xCircle),
      EvidenceVerdict.inconclusive => (semantic.neutral, AppIcons.question),
    };
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
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// The comparison's own state, as one word on the ramp.
class OutcomeLabel extends StatelessWidget {
  const OutcomeLabel({required this.comparison, super.key});

  final Comparison comparison;

  @override
  Widget build(BuildContext context) {
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
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontFamily: kMonoFamily,
      ),
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
