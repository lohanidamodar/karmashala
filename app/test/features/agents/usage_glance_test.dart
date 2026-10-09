import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/usage_glance.dart';
import 'package:karmashala/src/features/agents/presentation/usage_glance.dart';
import 'package:karmashala/src/features/sessions/application/capacity_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import 'usage_fixtures.dart';

/// The Usage glance for the Agent dashboard (round 84): each account's main
/// window as a bar with "~14:20", the limits' occupancy, and a click that
/// opens the Usage tab.
void main() {
  late TestMachine db;

  setUp(() {
    db = seedUsageDatabase();
    seedUsage(db.server, agentInstallation(), usage: usageSnapshot());
  });

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

  Future<List<String?>> pump(
    WidgetTester tester, {
    double width = 280,
    double textScale = 1,
    CapacitySnapshot capacity = CapacitySnapshot.empty,
  }) async {
    final opened = <String?>[];
    final container = ProviderContainer(
      overrides: [
        await db.server.override(),
        clockProvider.overrideWithValue(MovableClock(testTime)),
        capacityNowProvider.overrideWithValue(capacity),
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
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: UsageGlance(onOpen: opened.add),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  testWidgets('each account\'s main window, with when it runs out', (
    tester,
  ) async {
    seedSteadyHistory();
    await pump(tester);
    final text = find.textContaining(RegExp(r'^62% · ~\d\d:\d\d$'));
    expect(text, findsOneWidget);
    expect(
      tester.widget<Text>(text).style?.color,
      SemanticColors.forBrightness(Brightness.light).attention,
    );
    expect(find.text('Claude · 5-hour'), findsOneWidget);
  });

  testWidgets('without recent readings it says so, not a guess', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('62% · no forecast yet'), findsOneWidget);
  });

  testWidgets('limit occupancy sits under the bars', (tester) async {
    await pump(
      tester,
      capacity: CapacitySnapshot(
        limits: const LaunchLimits(global: 4),
        running: 3,
        waiters: [
          LaunchWaiter(
            ticketId: 't',
            label: 'x',
            priority: LaunchPriority.background,
            place: 1,
            reason: 'r',
            enqueuedAt: testTime,
          ),
        ],
      ),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('usage-glance-occupancy')))
          .data,
      '3/4 running · 1 waiting',
    );
  });

  testWidgets('a click opens Usage, on the account clicked', (tester) async {
    final opened = await pump(tester);
    await tester.tap(find.text('Claude · 5-hour'));
    await tester.pump();
    expect(opened.single, isNotNull);
    opened.clear();
    await tester.tap(
      find.byKey(const ValueKey('usage-glance')),
      warnIfMissed: false,
    );
    await tester.tapAt(
      tester.getBottomLeft(find.byKey(const ValueKey('usage-glance'))) +
          const Offset(2, -2),
    );
    await tester.pump();
    expect(opened, contains(null));
  });

  test('the main window is the shortest measured one', () {
    final usage = usageSnapshot(percent: 10);
    expect(usageMainWindow(usage)?.label, '5-hour');
    expect(usageMainWindow(antigravitySnapshot()), isNull);
  });

  for (final width in const [200.0, 360.0]) {
    for (final scale in const [1.0, 1.6]) {
      testWidgets('lays out at ${width.round()}px, text ${scale}x', (
        tester,
      ) async {
        seedSteadyHistory();
        await pump(tester, width: width, textScale: scale);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
