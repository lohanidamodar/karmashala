// A diff stat in words, and its label.

part of '../session_card.dart';

/// [DiffStatLabel]'s facts in words, for a hover: `↑2  +949 −10`.
String diffStatWords(SessionDiffStat stat) {
  final ahead = stat.commitsAhead;
  return [
    if (ahead != null && ahead > 0) '↑$ahead',
    if (stat.hasLineCounts)
      [
        if (stat.added != null) '+${stat.added}',
        if (stat.removed != null) '−${stat.removed}',
      ].join(' ')
    else if ((stat.changedFiles ?? 0) > 0)
      '${stat.changedFiles} changed',
  ].join('  ');
}

/// The progress indicator, in MonoCode's terms: `+949 −10` when line counts
/// exist, and what git can actually answer today when they do not.
class DiffStatLabel extends StatelessWidget {
  const DiffStatLabel({required this.stat, super.key});

  final SessionDiffStat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(letterSpacing: 0);
    final ahead = stat.commitsAhead;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ahead != null && ahead > 0) ...[
          Text(
            '↑$ahead',
            style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: Insets.xsm),
        ],
        if (stat.hasLineCounts) ...[
          if (stat.added != null)
            Text(
              '+${stat.added}',
              style: style?.copyWith(color: semantic.diffAdded),
            ),
          if (stat.added != null && stat.removed != null)
            const SizedBox(width: Insets.xs),
          if (stat.removed != null)
            Text(
              '−${stat.removed}',
              style: style?.copyWith(color: semantic.diffRemoved),
            ),
        ] else if ((stat.changedFiles ?? 0) > 0)
          Text(
            '${stat.changedFiles} changed',
            style: style?.copyWith(color: semantic.diffAdded),
          ),
      ],
    );
  }
}
