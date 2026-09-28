import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../explorer/application/explorer_actions.dart';
import '../../application/session_token_totals.dart' show formatTokenCount;
import '../../application/usage_session_tokens.dart';
import '../usage_chip.dart' show formatUsageDuration;

/// **Where the tokens went**, by project and by model, over the sessions of
/// the account's agent last active in the range. Whole-session totals: a
/// session's file does not say which tokens fell in which hour.
class UsageWhereItWent extends StatelessWidget {
  const UsageWhereItWent({required this.breakdown, super.key});

  final UsageBreakdown breakdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final colour = SemanticColors.of(context).working;
    List<BarDatum> bars(List<(String, int)> entries) => [
      for (final (label, tokens) in entries)
        BarDatum(
          label: label,
          value: tokens.toDouble(),
          valueLabel: formatTokenCount(tokens),
        ),
    ];
    final unsplit = breakdown.unsplitByModel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const EyebrowLabel('By project'),
        const SizedBox(height: Insets.xs),
        RankedBars(bars: bars(breakdown.byProject), color: colour),
        const SizedBox(height: Insets.md),
        const EyebrowLabel('By model'),
        const SizedBox(height: Insets.xs),
        if (breakdown.byModel.isEmpty)
          Text(
            'Not recorded — these sessions’ files keep one running total, '
            'not one per model.',
            style: muted,
          )
        else ...[
          RankedBars(bars: bars(breakdown.byModel), color: colour),
          if (unsplit > 0)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                '${formatTokenCount(unsplit)} more from sessions whose files '
                'do not split tokens by model.',
                style: muted,
              ),
            ),
        ],
      ],
    );
  }
}

/// **The sessions that recorded the most tokens**, most first. A row opens its
/// session the way the Sessions list does.
class UsageHeaviestSessions extends ConsumerWidget {
  const UsageHeaviestSessions({
    required this.sessions,
    required this.now,
    super.key,
  });

  final List<UsageSessionRow> sessions;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in sessions)
          _HeaviestRow(
            row: row,
            now: now,
            onOpen: () => _open(context, ref, row.sessionId),
          ),
      ],
    );
  }

  /// The Sessions list's own open: reattach, resume or select, and a sentence
  /// only when there is one to say.
  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await ref
        .read(explorerActionsProvider)
        .openNative(sessionId);
    final message = result.message;
    if (message != null) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _HeaviestRow extends StatelessWidget {
  const _HeaviestRow({
    required this.row,
    required this.now,
    required this.onOpen,
  });

  final UsageSessionRow row;
  final DateTime now;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final last = row.lastActivityAt;
    final where = [
      row.project,
      if (last != null) '${formatUsageDuration(now.difference(last))} ago',
    ].join(' · ');
    final tokens = formatTokenCount(row.tokens ?? 0);
    return Semantics(
      button: true,
      label: '${row.title}, $where, $tokens tokens. Opens the session.',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          hoverColor: tones.selected,
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: 6,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      Text(
                        where,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.sm),
                Text(
                  tokens,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
