import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../../app/shell/workbench_tabs.dart' show openUsageTab;
import '../../../../app/widgets/dashboard_glance.dart';
import '../../../../core/util/clock_provider.dart';
import '../../../agents/application/usage_glance.dart';
import '../../../agents/presentation/usage_glance.dart';
import '../overview_glances.dart' show GlanceNote;

/// **Usage** (round 84): each account's window with its forecast, and how
/// full the session limits are. A row clicked opens the Usage tab on its
/// account.
const usageGlance = DashboardGlance(
  id: 'usage',
  title: 'Usage',
  icon: AppIcons.chartBar,
  build: _body,
  onOpen: _open,
);

void _open(BuildContext context, WidgetRef ref) => openUsageTab(ref);

Widget _body(BuildContext context) => GlanceScope.compactOf(context)
    ? const UsageGlanceLine()
    : Consumer(
        builder: (context, ref, _) => UsageGlance(
          onOpen: (accountId) => openUsageTab(ref, accountId: accountId),
        ),
      );

/// The Usage glance in one line, for a phone's strip: the account nearest
/// its limit — its window, how full, its forecast — else the occupancy.
class UsageGlanceLine extends ConsumerWidget {
  const UsageGlanceLine({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(usageGlanceProvider);
    final now = ref.watch(clockProvider).nowUtc();
    final theme = Theme.of(context);
    UsageGlanceAccount? first;
    for (final account in data.accounts) {
      final warns = account.forecast.warns();
      final best = first;
      if (best == null ||
          (warns && !best.forecast.warns()) ||
          (warns == best.forecast.warns() &&
              account.window.percent! > best.window.percent!)) {
        first = account;
      }
    }
    if (first == null) {
      return GlanceNote(data.occupancy ?? 'No usage read yet');
    }
    final name = first.agentName.split(' ').first;
    final warns = first.forecast.warns();
    return Text(
      [
        '$name · ${first.window.label} ${first.window.percent!.round()}%',
        usageGlanceForecast(first.forecast, now),
        ?data.occupancy,
      ].join(' · '),
      key: const ValueKey('usage-glance-line'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: warns ? SemanticColors.of(context).attention : null,
      ),
    );
  }
}
