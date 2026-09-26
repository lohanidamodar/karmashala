import 'package:agent_cli/usage.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/agents/data/usage_sample_dao.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip.dart';
import 'package:karmashala/src/features/agents/presentation/usage_chip_popover.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/charts.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import 'usage_fixtures.dart';
import '../../support/workspace_mirror.dart';

/// The chip's hover card: meters with countdowns and pace, a sparkline where
/// there is history, and the plain sentence kept for screen readers.
void main() {
  late AppDatabase db;
  late MovableClock clock;
  late FakeAgentUsageService service;

  late Override data;

  setUp(() async {
    db = seedUsageDatabase();
    data = await mirroredServer(db).override();
    clock = MovableClock(testTime);
    service = FakeAgentUsageService(clock: clock);
  });
  tearDown(() => db.close());

  List<Override> overrides() => [
    databaseProvider.overrideWithValue(db),
    data,
    clockProvider.overrideWithValue(clock),
    agentUsageServiceProvider.overrideWithValue(service),
  ];

  void seedHistory() {
    final dao = UsageSampleDao(db);
    for (var i = 0; i < 6; i++) {
      dao.insert(
        UsageSample(
          accountKey: 'claudeCode@windows',
          windowLabel: '5-hour',
          span: kUsageFiveHourWindow,
          percent: 10.0 * i,
          recordedAt: testTime.subtract(Duration(minutes: 30 * (6 - i))),
        ),
      );
    }
  }

  testWidgets('hovering the chip opens a card of meters, with pace', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: overrides());
    addTearDown(container.dispose);
    container.read(selectedSessionIdProvider.notifier).select('s1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: UsageChip(sessionId: 's1')),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('62% · 2h11m'), findsOneWidget);
    expect(find.byType(UsageChipPopover), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(UsageChip)));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(UsageChipPopover), findsOneWidget);
    expect(find.byType(LinearMeter), findsNWidgets(2));
    expect(find.textContaining('62% · resets in 2h11m'), findsOneWidget);
    expect(find.text('Slightly ahead of pace'), findsOneWidget);
    expect(find.text('owner@example.com'), findsOneWidget);
    expect(find.text('Checked just now'), findsOneWidget);
    expect(find.text('Click for usage & limits'), findsOneWidget);

    await mouse.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(seconds: 1));
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the chip still names itself in words for a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final container = ProviderContainer(overrides: overrides());
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: UsageChip(sessionId: 's1')),
          ),
        ),
      ),
    );
    await tester.pump();
    final data = tester.getSemantics(find.byType(UsageChip)).getSemanticsData();
    expect(
      data.tooltip,
      allOf(contains('5-hour · 62% · resets in 2h11m'), contains('Checked')),
    );
    container.read(windowFocusedProvider.notifier).set(false);
    await tester.pump();
    semantics.dispose();
  });

  Widget popover(UsageChipView view) => ProviderScope(
    overrides: overrides(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: UsageChipPopover(
            view: view,
            accountKey: 'claudeCode@windows',
            agentId: 'claudeCode',
            environmentId: 'windows',
          ),
        ),
      ),
    ),
  );

  testWidgets('history becomes a sparkline beside the pace', (tester) async {
    seedHistory();
    final view = usageChipViewFor(
      AsyncValue.data(usageSnapshot(percent: 62)),
      testTime,
    );
    await tester.pumpWidget(popover(view));
    final sparks = tester.widgetList<Sparkline>(find.byType(Sparkline));
    expect(sparks, hasLength(1), reason: 'only the 5-hour window has history');
    expect(sparks.single.values, [0, 10, 20, 30, 40, 50, 62]);
  });

  testWidgets('nothing read yet: the card is the sentence', (tester) async {
    final view = usageChipViewFor(const AsyncValue.loading(), testTime);
    await tester.pumpWidget(popover(view));
    expect(find.text('Checking agent usage…'), findsOneWidget);
    expect(find.byType(LinearMeter), findsNothing);
  });

  testWidgets('the card survives the window matrix', (tester) async {
    seedHistory();
    final view = usageChipViewFor(
      AsyncValue.data(
        AgentUsage(
          fetchedAt: testTime,
          email: 'a-rather-long-address-for-a-narrow-card@example.com',
          windows: [
            UsageWindow(
              label: '5-hour',
              percent: 91,
              resetsAt: testTime.add(const Duration(hours: 4)),
              span: kUsageFiveHourWindow,
            ),
            UsageWindow(
              label: '7-day',
              percent: 40,
              resetsAt: testTime.add(const Duration(days: 3)),
              span: kUsageSevenDayWindow,
            ),
            const UsageWindow(
              label: 'Claude Opus Fable Sonnet · weekly',
              percent: 3,
            ),
            const UsageWindow(label: 'Gemini Code Assist'),
          ],
        ),
      ),
      testTime,
    );
    await expectSurvivesWindowMatrix(
      tester,
      build: () => popover(view),
      because: 'the hover card opens at the smallest window too',
    );
  });
}
