import 'package:agent_cli/usage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/usage_accounts.dart';
import 'package:karmashala/src/features/agents/application/usage_forecast.dart';
import 'package:karmashala/src/features/agents/application/usage_forecast_notices.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AccountUsageState;
import 'package:karmashala_notifications/policy.dart';

/// The warning thresholds and the optional notification (round 84): a
/// forecast warns when it runs out at least 15 minutes before its reset, and
/// says so as a notification only when Settings → Notifications turns it on.
void main() {
  final readAt = DateTime.utc(2026, 10, 9, 12);

  UsageForecast forecast({
    required Duration outIn,
    required Duration resetIn,
  }) => UsageForecast(
    kind: outIn < resetIn
        ? UsageForecastKind.runsOut
        : UsageForecastKind.lastsUntilReset,
    windowLabel: '5-hour',
    percent: 60,
    readAt: readAt,
    resetsAt: readAt.add(resetIn),
    ratePerHour: 12,
    runsOutAt: readAt.add(outIn),
  );

  UsageAccount account() {
    final usage = AgentUsage(
      windows: const [],
      fetchedAt: readAt,
      email: 'me@example.com',
    );
    final state = AccountUsageState(
      accountKey: 'claudeCode@windows',
      agentId: 'claudeCode',
      environmentId: 'windows',
      usage: usage,
    );
    return UsageAccount(
      agentId: 'claudeCode',
      email: 'me@example.com',
      latest: state,
      states: [state],
    );
  }

  group('warning thresholds', () {
    test('runs out 15 minutes or more before the reset: warns', () {
      expect(
        forecast(
          outIn: const Duration(hours: 1),
          resetIn: const Duration(hours: 1, minutes: 15),
        ).warns(),
        isTrue,
      );
    });

    test('runs out less than 15 minutes before: no warning', () {
      expect(
        forecast(
          outIn: const Duration(hours: 1),
          resetIn: const Duration(hours: 1, minutes: 14),
        ).warns(),
        isFalse,
      );
    });

    test('lasts until the reset, idle or not enough data: no warning', () {
      expect(
        forecast(
          outIn: const Duration(hours: 2),
          resetIn: const Duration(hours: 1),
        ).warns(),
        isFalse,
      );
      for (final kind in [
        UsageForecastKind.idle,
        UsageForecastKind.notEnoughData,
        UsageForecastKind.notMeasured,
      ]) {
        expect(
          UsageForecast(kind: kind, windowLabel: '5-hour').warns(),
          isFalse,
          reason: '$kind',
        );
      }
    });
  });

  group('the notification', () {
    final warning = UsageForecastWarning(
      account: account(),
      forecast: forecast(
        outIn: const Duration(hours: 1),
        resetIn: const Duration(hours: 2),
      ),
    );

    test('is off by default', () {
      expect(const NotificationSettings().usageForecast, isFalse);
      expect(
        usageForecastNotification(
          warning,
          const NotificationSettings(),
          readAt,
        ),
        isNull,
      );
    });

    test('names the account and says the forecast when on', () {
      final request = usageForecastNotification(
        warning,
        const NotificationSettings(usageForecast: true),
        readAt,
      );
      expect(request, isNotNull);
      expect(request!.title, contains('me@example.com'));
      expect(request.title, contains('5-hour reset'));
      expect(request.body, startsWith('At this pace: runs out ~'));
    });

    test('Notify me: Never keeps it quiet', () {
      expect(
        usageForecastNotification(
          warning,
          const NotificationSettings(
            usageForecast: true,
            level: NotifyLevel.nothing,
          ),
          readAt,
        ),
        isNull,
      );
    });

    test('a new reset is a new window to tell of', () {
      final next = UsageForecastWarning(
        account: account(),
        forecast: forecast(
          outIn: const Duration(hours: 6),
          resetIn: const Duration(hours: 7),
        ),
      );
      expect(next.key, isNot(warning.key));
    });

    test('the switch survives a round trip, and a missing key is off', () {
      const on = NotificationSettings(usageForecast: true);
      expect(NotificationSettings.fromJson(on.toJson()).usageForecast, isTrue);
      expect(NotificationSettings.fromJson(const {}).usageForecast, isFalse);
    });
  });
}
