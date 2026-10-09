import 'package:agent_cli/usage.dart' show usageSeverityFor;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/workbench_tabs.dart' show openUsageTab;
import '../../../core/util/clock_provider.dart';
import '../application/usage_forecast.dart';
import '../application/usage_glance.dart';
import 'usage_chip.dart' show formatResetClock;
import 'usage_window_meter.dart';

/// The forecast in the few characters a glance has: "~14:20" when it runs
/// out first, else what it is.
String usageGlanceForecast(UsageForecast forecast, DateTime now) =>
    switch (forecast.kind) {
      UsageForecastKind.runsOut =>
        '~${formatResetClock(forecast.runsOutAt!, now)}',
      UsageForecastKind.lastsUntilReset => 'lasts',
      UsageForecastKind.idle => 'idle',
      UsageForecastKind.spent => 'spent',
      UsageForecastKind.notEnoughData => 'no forecast yet',
      UsageForecastKind.notMeasured => 'not measured',
    };

/// **The Usage glance** (round 84) for the Agent dashboard: each account's
/// main window as a compact bar with its forecast ("~14:20"), and how full
/// the session limits are. Read-only; a click opens the Usage tab — on the
/// account clicked, when one was.
///
/// A plain widget with [onOpen] until the dashboard's glance slot takes it
/// (round 82); null [onOpen] opens the Usage tab itself.
class UsageGlance extends ConsumerWidget {
  const UsageGlance({this.onOpen, super.key});

  /// Opens the full page; the account id ([usageAccountId]) when a row was
  /// clicked, null for the glance as a whole.
  final ValueChanged<String?>? onOpen;

  void _open(WidgetRef ref, String? accountId) {
    final open = onOpen;
    if (open != null) return open(accountId);
    openUsageTab(ref, accountId: accountId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final data = ref.watch(usageGlanceProvider);
    final now = ref.watch(clockProvider).nowUtc();
    return Semantics(
      container: true,
      button: true,
      label: 'Usage. Opens the Usage tab.',
      child: InkWell(
        key: const ValueKey('usage-glance'),
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () => _open(ref, null),
        child: Padding(
          padding: const EdgeInsets.all(Insets.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (data.isEmpty) Text('No usage read yet', style: muted),
              for (final account in data.accounts)
                _AccountBar(
                  account: account,
                  now: now,
                  onTap: () => _open(ref, account.accountId),
                ),
              if (data.occupancy case final occupancy?)
                Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: Row(
                    children: [
                      Icon(
                        AppIcons.stack,
                        size: Chrome.iconSmall,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Insets.xs),
                      Expanded(
                        child: Text(
                          occupancy,
                          key: const ValueKey('usage-glance-occupancy'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountBar extends StatelessWidget {
  const _AccountBar({
    required this.account,
    required this.now,
    required this.onTap,
  });

  final UsageGlanceAccount account;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final percent = account.window.percent!;
    final forecast = account.forecast;
    final warns = forecast.warns();
    final ahead = usageGlanceForecast(forecast, now);
    final name = account.agentName.split(' ').first;
    return InkWell(
      key: ValueKey('usage-glance-${account.accountId}'),
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Wraps, so a narrow tile or a large text size puts the
            // forecast under the name instead of squeezing either.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: Insets.xs,
              children: [
                Text(
                  '$name · ${account.window.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '${percent.round()}% · $ahead',
                  key: ValueKey('usage-glance-forecast-${account.accountId}'),
                  style: small?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: warns
                        ? SemanticColors.of(context).attention
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.xxs),
            LinearMeter(
              value: percent / 100,
              color: usageSeverityColor(context, usageSeverityFor(percent)),
              semanticsLabel:
                  '${account.agentName} ${account.window.label}: '
                  '${percent.round()}%. ${usageForecastSentence(forecast, now)}',
            ),
          ],
        ),
      ),
    );
  }
}
