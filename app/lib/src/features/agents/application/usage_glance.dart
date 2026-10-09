import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:riverpod/riverpod.dart';

import '../../sessions/application/capacity_providers.dart';
import '../presentation/usage_tab/usage_tab_state.dart' show usageAccountId;
import 'usage_accounts.dart';
import 'usage_forecast.dart';

/// One account on the Usage glance: its main window and that window's
/// forecast.
@immutable
class UsageGlanceAccount {
  const UsageGlanceAccount({
    required this.accountId,
    required this.agentName,
    required this.window,
    required this.forecast,
    this.email,
  });

  /// `usageAccountId`, for opening the Usage tab on it.
  final String accountId;
  final String agentName;
  final String? email;
  final UsageWindow window;
  final UsageForecast forecast;
}

/// What the dashboard's Usage glance shows: each measured account's main
/// window with its forecast, and how full the session limits are.
@immutable
class UsageGlanceData {
  const UsageGlanceData({required this.accounts, this.occupancy});

  final List<UsageGlanceAccount> accounts;

  /// "3/4 running · 1 waiting", or null while no limit is set and nothing
  /// waits.
  final String? occupancy;

  bool get isEmpty => accounts.isEmpty && occupancy == null;
}

/// An account's main window: the shortest measured one — the one that runs
/// out first in a day — or null when nothing is measured.
UsageWindow? usageMainWindow(AgentUsage? usage) {
  UsageWindow? main;
  for (final w in usage?.windows ?? const <UsageWindow>[]) {
    if (w.percent == null) continue;
    final span = w.span;
    final best = main?.span;
    if (main == null ||
        (span != null && (best == null || span < best)) ||
        (span == best && w.percent! > main.percent!)) {
      main = w;
    }
  }
  return main;
}

/// The glance's data, from the accounts the Usage tab shows and the same
/// forecast every usage surface draws. Kept in the usage feature: the
/// dashboard imports only the glance widget.
final usageGlanceProvider = Provider.autoDispose<UsageGlanceData>((ref) {
  final accounts = ref.watch(usageAccountsProvider);
  return UsageGlanceData(
    accounts: [
      for (final account in accounts)
        if (usageMainWindow(account.latest.usage) case final window?)
          UsageGlanceAccount(
            accountId: usageAccountId(account),
            agentName: AgentRegistry.builtIn.displayNameFor(account.agentId),
            email: account.email,
            window: window,
            forecast:
                ref.watch(
                  usageForecastsProvider(account.latest.accountKey),
                )[window.label] ??
                UsageForecast(
                  kind: UsageForecastKind.notEnoughData,
                  windowLabel: window.label,
                ),
          ),
    ],
    occupancy: capacitySummary(ref.watch(capacityNowProvider)),
  );
});
