import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala_notifications/toasts.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/util/clock_provider.dart';
import '../../notifications/application/notification_providers.dart';
import '../presentation/usage_window_meter.dart' show usageForecastSentence;
import 'usage_accounts.dart';
import 'usage_forecast.dart';

/// One window whose forecast runs out well before it resets.
@immutable
class UsageForecastWarning {
  const UsageForecastWarning({required this.account, required this.forecast});

  final UsageAccount account;
  final UsageForecast forecast;

  /// Once per account, window and period: a new reset is a new window.
  String get key =>
      '${account.latest.accountKey}\u0000${forecast.windowLabel}\u0000'
      '${forecast.resetsAt?.toIso8601String()}';
}

/// **Every window, of every account, that warns** — the chip's amber, the
/// glance's and the optional notification's one source.
final usageForecastWarningsProvider =
    Provider.autoDispose<List<UsageForecastWarning>>((ref) {
      final accounts = ref.watch(usageAccountsProvider);
      return [
        for (final account in accounts)
          for (final forecast
              in ref
                  .watch(usageForecastsProvider(account.latest.accountKey))
                  .values)
            if (forecast.warns())
              UsageForecastWarning(account: account, forecast: forecast),
      ];
    });

/// The notification for [warning], or null when Settings → Notifications
/// keeps it quiet: off unless "Usage running out early" is on.
NotificationRequest? usageForecastNotification(
  UsageForecastWarning warning,
  NotificationSettings settings,
  DateTime now,
) {
  if (!settings.usageForecast || settings.level == NotifyLevel.nothing) {
    return null;
  }
  final agent = AgentRegistry.builtIn.displayNameFor(warning.account.agentId);
  final who = warning.account.email;
  return NotificationRequest(
    title:
        '$agent${who == null ? '' : ' ($who)'} will run out before its '
        '${warning.forecast.windowLabel} reset',
    body: usageForecastSentence(warning.forecast, now),
  );
}

/// Tells each new warning once, as Settings allow. Must be watched.
class UsageForecastNotices extends Notifier<int> {
  final _told = <String>{};

  @override
  int build() {
    ref.listen(
      usageForecastWarningsProvider,
      (_, warnings) => present(warnings),
      fireImmediately: true,
    );
    return 0;
  }

  void present(List<UsageForecastWarning> warnings) {
    final settings = ref.read(notificationSettingsControllerProvider);
    final phone = ref.read(capabilitiesProvider).localNotifications;
    final now = ref.read(clockProvider).nowUtc();
    for (final warning in warnings) {
      final request = usageForecastNotification(warning, settings, now);
      // Off is not "told": turned on mid-window, it still says so once.
      if (request == null || _told.contains(warning.key)) continue;
      if (!phone &&
          settings.onlyWhenUnfocused &&
          ref.read(windowFocusedProvider)) {
        continue;
      }
      _told.add(warning.key);
      state++;
      unawaited(ref.read(notificationPresenterProvider).show(request));
    }
  }
}

final usageForecastNoticesProvider =
    NotifierProvider<UsageForecastNotices, int>(UsageForecastNotices.new);
