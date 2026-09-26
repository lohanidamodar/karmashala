import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_usage_providers.dart';
import 'package:karmashala/src/features/settings/presentation/agent_usage_section.dart';
import 'package:karmashala_ui/charts.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/window_matrix.dart';
import '../agents/usage_fixtures.dart';
import '../../support/fake_data_server.dart';

/// Settings › Accounts & usage › Usage & limits, redesigned: meters in status
/// colours with a pace tick, the recorded history as a chart, spend per day,
/// and a comparison across accounts — at every window size the app supports.
void main() {
  late FakeDataServer server;
  late DataClient client;
  late MovableClock clock;
  late _PerAgentUsageService service;

  final claude = agentInstallation(id: 'a1', agentId: AgentIds.claudeCode);
  final codex = agentInstallation(
    id: 'a2',
    agentId: AgentIds.codex,
    path: r'C:\Users\me\.bin\codex.exe',
  );

  setUp(() async {
    server = FakeDataServer()..environmentRows.upsert(windowsEnv());
    client = await server.connect();
    clock = MovableClock(testTime);
    service = _PerAgentUsageService(clock: clock);
  });

  void seedHistory(String account) {
    final dao = server.usageRows;
    for (var i = 0; i <= 12; i++) {
      final at = testTime.subtract(Duration(minutes: 20 * (12 - i)));
      dao.insert(
        UsageSample(
          accountKey: account,
          windowLabel: '5-hour',
          span: kUsageFiveHourWindow,
          percent: 5.0 * i,
          resetsAt: testTime.add(const Duration(hours: 2, minutes: 11)),
          recordedAt: at,
        ),
      );
    }
    for (var day = 6; day >= 0; day--) {
      dao.insert(
        UsageSample(
          accountKey: account,
          windowLabel: '7-day',
          span: kUsageSevenDayWindow,
          percent: 40.0 - day * 5,
          recordedAt: testTime.subtract(Duration(days: day, hours: 1)),
        ),
      );
    }
  }

  Widget page(List<AgentInstallation> installations) => ProviderScope(
    overrides: [
      dataClientProvider.overrideWithValue(client),
      clockProvider.overrideWithValue(clock),
      agentUsageServiceProvider.overrideWithValue(service),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.lg),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: UsageSection(installations: installations),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets(
    'before anything is read, the card says so and offers the check',
    (tester) async {
      await tester.pumpWidget(page([claude]));
      expect(find.textContaining('Not read yet'), findsOneWidget);
      expect(find.text('Check usage'), findsOneWidget);
      expect(find.byType(LinearMeter), findsNothing);
    },
  );

  testWidgets('while reading, a spinner stands in for the button', (
    tester,
  ) async {
    service.hold = true;
    await tester.pumpWidget(page([claude]));
    await tester.tap(find.text('Check usage'));
    await tester.pump();
    expect(find.byType(InlineSpinner), findsOneWidget);
    expect(find.textContaining('Reading this account'), findsOneWidget);
    service.release();
    await tester.pump();
    await tester.pump();
    expect(find.byType(InlineSpinner), findsNothing);
    expect(find.textContaining('62%'), findsOneWidget);
  });

  testWidgets('a meter is drawn in status colours, never the accent, with a '
      'pace tick', (tester) async {
    service.answers[AgentIds.claudeCode] = usageSnapshot(percent: 62);
    await service.fetch(claude, const []);
    await tester.pumpWidget(page([claude]));

    final meters = tester.widgetList<LinearMeter>(find.byType(LinearMeter));
    expect(meters, hasLength(2));
    final semantic = SemanticColors.forBrightness(Brightness.light);
    expect(meters.first.color, semantic.idle);
    expect(meters.first.marker, closeTo((300 - 131) / 300, 1e-6));
    expect(
      meters.map((m) => m.color),
      isNot(
        contains(
          Theme.of(
            tester.element(find.byType(UsageSection)),
          ).colorScheme.primary,
        ),
      ),
    );
    // 62% at 56% of the window: a little ahead of an even rate.
    expect(find.text('Slightly ahead of pace'), findsOneWidget);
  });

  testWidgets('a nearly spent window over pace says when it runs out', (
    tester,
  ) async {
    service.answers[AgentIds.claudeCode] = usageSnapshot(
      percent: 90,
      resetsIn: const Duration(hours: 4),
    );
    await service.fetch(claude, const []);
    await tester.pumpWidget(page([claude]));

    final meter = tester.widget<LinearMeter>(find.byType(LinearMeter).first);
    expect(
      meter.color,
      SemanticColors.forBrightness(Brightness.light).attention,
    );
    expect(find.textContaining('Over pace — runs out in'), findsOneWidget);
  });

  testWidgets('with no history yet, the chart explains itself', (tester) async {
    await service.fetch(claude, const []);
    await tester.pumpWidget(page([claude]));
    expect(find.byType(TimeSeriesChart), findsNothing);
    expect(find.textContaining('No history for 5-hour yet'), findsOneWidget);
  });

  testWidgets('recorded history becomes a chart, and weekly spend bars', (
    tester,
  ) async {
    seedHistory(usageAccountKey(claude));
    await service.fetch(claude, const []);
    await tester.pumpWidget(page([claude]));
    // The history is asked of the server; its answer is a frame later.
    await tester.pump();

    expect(find.byType(TimeSeriesChart), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    expect(find.text('7-day spent per day'), findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(
        RegExp(r'^5-hour over the last 24 hours: from 0% to 60%, peak 60%$'),
      ),
      findsOneWidget,
    );
    semantics.dispose();

    await tester.tap(find.widgetWithText(ChoiceChip, '7-day'));
    await tester.pump();
    expect(
      tester.widget<TimeSeriesChart>(find.byType(TimeSeriesChart)).points,
      hasLength(7),
    );
  });

  testWidgets('two accounts with readings are compared side by side', (
    tester,
  ) async {
    service.answers[AgentIds.claudeCode] = usageSnapshot(percent: 62);
    service.answers[AgentIds.codex] = usageSnapshot(percent: 97);
    await service.fetch(claude, const []);
    await service.fetch(codex, const []);
    await tester.pumpWidget(page([claude, codex]));

    expect(find.text('Closest to a limit, per account'), findsOneWidget);
    final ranked = tester.widget<RankedBars>(find.byType(RankedBars));
    expect(ranked.bars.map((b) => b.valueLabel), ['62% used', '97% used']);
    expect(
      ranked.bars.last.color,
      SemanticColors.forBrightness(Brightness.light).failure,
    );
  });

  testWidgets('one account has nothing to compare against', (tester) async {
    await service.fetch(claude, const []);
    await tester.pumpWidget(page([claude, codex]));
    expect(find.byType(RankedBars), findsNothing);
  });

  testWidgets('the page survives the window matrix with everything on it', (
    tester,
  ) async {
    seedHistory(usageAccountKey(claude));
    service.answers[AgentIds.codex] = usageSnapshot(
      percent: 97,
      resetsIn: const Duration(hours: 4, minutes: 30),
    );
    await service.fetch(claude, const []);
    await service.fetch(codex, const []);
    await expectSurvivesWindowMatrix(
      tester,
      build: () => page([claude, codex]),
      because: 'the usage page is read at the smallest window too',
    );
  });
}

/// Answers per agent, and can hold a request open to show the loading state.
class _PerAgentUsageService extends FakeAgentUsageService {
  _PerAgentUsageService({super.clock});

  final answers = <String, AgentUsage>{};
  bool hold = false;
  Completer<void>? _gate;

  void release() {
    hold = false;
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<AgentUsage> fetchFresh(
    AgentInstallation installation,
    List<ExecutionEnvironment> environments,
  ) async {
    if (hold) await (_gate ??= Completer<void>()).future;
    calls.add(installation);
    return answers[installation.agentId] ??
        usageSnapshot(fetchedAt: clock.nowUtc());
  }
}
