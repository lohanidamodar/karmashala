import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../app/shell/reveal_session.dart' show peekSessionOnDashboard;
import '../../application/session_token_totals.dart' show formatTokenCount;
import '../../application/usage_session_tokens.dart';
import '../usage_chip.dart' show formatUsageDuration;
import 'usage_breakdown_section.dart' show UsageRankedBars;
import 'usage_tab_state.dart';

/// **Cost, where it is recorded** (round 84): what agents reported spending,
/// by project over the range, and today's most expensive sessions, each a
/// click from its peek. Every agent's sessions, since cost is a session's,
/// not an account's; nothing is estimated from tokens.
class UsageCostSection extends ConsumerWidget {
  const UsageCostSection({
    required this.rows,
    required this.range,
    required this.now,
    super.key,
  });

  final List<UsageSessionRow> rows;
  final UsageRange range;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final byProject = usageCostByProject(rows, since: now.subtract(range.span));
    final local = now.toLocal();
    final midnight = DateTime(local.year, local.month, local.day).toUtc();
    final today = usageMostExpensive(rows, since: midnight);
    final colour = SemanticColors.of(context).working;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const EyebrowLabel('Cost by project'),
        const SizedBox(height: Insets.xs),
        if (byProject.isEmpty)
          Text(
            'Not recorded — no session active in ${range.phrase} reported '
            'what it cost. Only agents that report spending say so; nothing '
            'is worked out from tokens.',
            key: const ValueKey('usage-cost-not-recorded'),
            style: muted,
          )
        else
          UsageRankedBars(
            bars: [
              for (final cost in byProject)
                BarDatum(
                  label: cost.currency == null || cost.currency!.isEmpty
                      ? cost.project
                      : '${cost.project} (${cost.currency})',
                  value: cost.amount,
                  valueLabel: formatMoney(cost.amount, cost.currency),
                ),
            ],
            color: colour,
          ),
        const SizedBox(height: Insets.xl),
        const EyebrowLabel('Most expensive today'),
        const SizedBox(height: Insets.xs),
        if (today.isEmpty)
          Text(
            'Not recorded — no session active today recorded tokens or cost.',
            style: muted,
          )
        else
          for (final row in today)
            _CostRow(
              row: row,
              now: now,
              onOpen: () => peekSessionOnDashboard(
                ProviderScope.containerOf(context),
                openId: row.sessionId,
              ),
            ),
      ],
    );
  }
}

/// What one session cost, as recorded: the reported amount when there is
/// one, its tokens, and "cost not recorded" in place of a guess.
String usageCostLine(UsageSessionRow row) {
  final amount = row.costAmount;
  final tokens = row.tokens;
  return [
    amount == null
        ? 'cost not recorded'
        : formatMoney(amount, row.costCurrency),
    if (tokens != null) '${formatTokenCount(tokens)} tokens',
  ].join(' · ');
}

class _CostRow extends StatelessWidget {
  const _CostRow({required this.row, required this.now, required this.onOpen});

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
    final cost = usageCostLine(row);
    return Semantics(
      button: true,
      label: '${row.title}, $where, $cost. Opens its peek.',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('usage-cost-row-${row.sessionId}'),
          borderRadius: BorderRadius.circular(Radii.sm),
          hoverColor: tones.selected,
          onTap: onOpen,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: UiDensity.of(context).padY,
            ),
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
                  '$where · $cost',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: muted?.copyWith(
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
