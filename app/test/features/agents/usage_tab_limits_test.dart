import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/usage_accounts.dart';
import 'package:karmashala/src/features/agents/application/usage_forecast.dart';
import 'package:karmashala/src/features/agents/application/usage_limits.dart';
import 'package:karmashala/src/features/agents/application/usage_session_tokens.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_tab_view.dart';
import 'package:karmashala/src/features/sessions/application/capacity_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/charts.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import 'usage_fixtures.dart';

/// The Usage tab (round 84): each window with its forecast and band, the
/// limits beside the usage, the one-tap pause until the reset that is round
/// 79's own pause, and the whole page at a phone's width and a large text
/// size.
void main() {
  late TestMachine db;
  late MovableClock clock;

  CapacitySnapshot busy({bool paused = false}) => CapacitySnapshot(
    limits: LaunchLimits(
      global: 4,
      machines: const {'windows': 2},
      pauseBackground: paused,
      holdBackgroundAbovePercent: 80,
    ),
    running: 3,
    scopes: const [
      CapacityScopeUse(
        scope: CapacityScope.global,
        key: '',
        label: 'All',
        used: 3,
        limit: 4,
      ),
      CapacityScopeUse(
        scope: CapacityScope.machine,
        key: 'windows',
        label: 'Windows',
        used: 2,
        limit: 2,
      ),
    ],
    waiters: [
      LaunchWaiter(
        ticketId: 't1',
        label: 'Nightly triage',
        priority: LaunchPriority.background,
        place: 1,
        reason: 'Waiting for a slot',
        enqueuedAt: testTime,
      ),
    ],
  );

  /// A steady recent pace: 24 points an hour, ending at the reading's 62%.
  void seedSteadyHistory() {
    for (var i = 12; i >= 1; i--) {
      db.server.usageRows.insert(
        UsageSample(
          accountKey: 'claudeCode@windows',
          windowLabel: '5-hour',
          span: kUsageFiveHourWindow,
          percent: 62.0 - 2 * i,
          recordedAt: testTime.subtract(Duration(minutes: 5 * i)),
        ),
      );
    }
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
    CapacitySnapshot? capacity,
    List<UsageSessionRow> rows = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        await db.server.override(),
        clockProvider.overrideWithValue(clock),
        serverOfferProvider.overrideWithValue(
          const ServerOffer(
            sameMachine: true,
            features: {'sessions.capacity', 'sessions.stats'},
          ),
        ),
        capacityNowProvider.overrideWithValue(capacity ?? busy()),
        usageSessionRowsProvider.overrideWith((ref) async => rows),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: UsageTabView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  setUp(() {
    db = seedUsageDatabase();
    seedUsage(db.server, agentInstallation(), usage: usageSnapshot());
    clock = MovableClock(testTime);
  });

  testWidgets('each window says its forecast, with a band on its chart', (
    tester,
  ) async {
    seedSteadyHistory();
    await pump(tester);
    final sentence = tester.widget<Text>(
      find.byKey(const ValueKey('usage-forecast-5-hour')),
    );
    expect(sentence.data, startsWith('At this pace: runs out ~'));
    expect(sentence.data, contains('before the reset at'));
    final chart = tester.widget<TimeSeriesChart>(
      find.byType(TimeSeriesChart).first,
    );
    expect(chart.forecast, hasLength(2));
    expect(chart.forecastBand, isNotEmpty);
    // The 7-day window has two readings at most: no rate, so no guess.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('usage-forecast-7-day')))
          .data,
      'Forecast: not enough data yet',
    );
  });

  testWidgets('the limits sit beside the usage', (tester) async {
    final c = await pump(tester);
    // The hold is a setting: Settings writes it, the server reads it.
    c
        .read(settingsControllerProvider.notifier)
        .setLaunchLimits(const LaunchLimits(holdBackgroundAbovePercent: 80));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('usage-limit-pause')),
      200,
    );
    expect(find.text('3/4'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('1 · 1 background'), findsOneWidget);
    expect(
      find.text('background waits above 80% of the 5-hour window'),
      findsOneWidget,
    );
    expect(find.text('Pause new background work'), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-limits-settings')), findsOneWidget);
  });

  testWidgets('a forecast that runs out early offers round 79\'s pause, '
      'until the reset', (tester) async {
    seedSteadyHistory();
    final c = await pump(tester);
    final offer = find.byKey(const ValueKey('usage-pause-until-reset'));
    await tester.scrollUntilVisible(offer, 200);
    expect(find.textContaining('Pause background work until'), findsOneWidget);
    expect(
      c.read(settingsControllerProvider).launchLimits.pauseBackground,
      isFalse,
    );

    await tester.tap(offer);
    await tester.pumpAndSettle();
    expect(
      c.read(settingsControllerProvider).launchLimits.pauseBackground,
      isTrue,
    );
    final reset = usageSnapshot().windows.first.resetsAt;
    expect(c.read(usagePauseUntilProvider), reset);
    c.read(usagePauseUntilProvider.notifier).forget();
  });

  testWidgets('no offer while the pause is already on, or without a warning', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('usage-pause-suggestion')), findsNothing);
  });

  test('the suggestion needs a warning, work on the account and no pause', () {
    final readAt = testTime;
    final warning = UsageForecast(
      kind: UsageForecastKind.runsOut,
      windowLabel: '5-hour',
      percent: 62,
      readAt: readAt,
      resetsAt: readAt.add(const Duration(hours: 2)),
      ratePerHour: 24,
      runsOutAt: readAt.add(const Duration(hours: 1)),
    );
    final state = AccountUsageState(
      accountKey: 'claudeCode@windows',
      agentId: 'claudeCode',
      environmentId: 'windows',
      usage: usageSnapshot(),
    );
    final account = UsageAccount(
      agentId: 'claudeCode',
      email: 'owner@example.com',
      latest: state,
      states: [state],
    );
    expect(
      usagePauseSuggestion(
        account: account,
        forecasts: {'5-hour': warning},
        capacity: busy(),
      ),
      warning,
    );
    expect(
      usagePauseSuggestion(
        account: account,
        forecasts: {'5-hour': warning},
        capacity: busy(paused: true),
      ),
      isNull,
    );
    expect(
      usagePauseSuggestion(
        account: account,
        forecasts: {'5-hour': warning},
        capacity: CapacitySnapshot.empty,
      ),
      isNull,
    );
  });

  for (final size in const [Size(360, 780), Size(412, 900), Size(1440, 900)]) {
    for (final scale in const [1.0, 1.6]) {
      testWidgets('lays out at ${size.width.round()}px, text ${scale}x', (
        tester,
      ) async {
        seedSteadyHistory();
        await pump(tester, size: size, textScale: scale);
        expect(tester.takeException(), isNull);
        // Down the whole page: every section lays out in the width.
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('usage-limit-pause')),
          300,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
