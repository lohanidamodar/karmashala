import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';

import 'package:karmashala/src/features/automations/application/automation_runs_page.dart';
import 'package:karmashala/src/features/automations/presentation/automation_runs_view.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/verdicts.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// Every run across every automation: filtered, opened to its steps, paged.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 7, 9);

  Automation automation(String id, String name) => Automation(
    id: id,
    repositoryId: 'r1',
    name: name,
    schedule: const AutomationSchedule.cron('0 2 * * *'),
    agentInstallationId: 'a1',
    prompt: 'fix',
    permissionMode: null,
    enabled: true,
    armedAt: now,
  );

  AutomationRun run(
    String id,
    String automationId, {
    AutomationRunState state = AutomationRunState.finished,
    Duration ago = Duration.zero,
    AutomationRunCause? startedBy,
    List<AutomationStepResult> steps = const [],
  }) => AutomationRun(
    id: id,
    automationId: automationId,
    scheduledFor: now.subtract(ago),
    firedAt: now.subtract(ago),
    state: state,
    reason: 'reason of $id',
    sessionId: 'session-$id',
    baseCheckpointId: 'cp-$id',
    finishedAt: state.isLive
        ? null
        : now.subtract(ago).add(const Duration(minutes: 3, seconds: 12)),
    startedBy: startedBy,
    stepResults: steps,
  );

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.automationRows
      ..insert(automation('nightly', 'Nightly'))
      ..insert(automation('review', 'Review'));
    server.automationRows
      ..insertRun(run('r1', 'nightly', ago: const Duration(hours: 7)))
      ..insertRun(
        run(
          'r2',
          'nightly',
          ago: const Duration(hours: 31),
          steps: [
            AutomationStepResult(
              kind: AutomationStepKind.tell,
              outcome: AutomationStepOutcome.done,
              detail: 'Sent to the session: "fix the tests"',
              at: now,
            ),
          ],
        ),
      )
      ..insertRun(
        run(
          'r3',
          'review',
          state: AutomationRunState.running,
          startedBy: AutomationRunCause.runNow,
        ),
      )
      ..insertRunCheck(
        AutomationCheckVerdict(
          runId: 'r2',
          ordinal: 1,
          name: 'tests',
          command: const ['dart', 'test'],
          verdict: VerificationVerdict.fail,
          reason: '2 failed',
          checkedAt: now,
        ),
      );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Scaffold(body: AutomationRunsView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every run, newest first, with its result, cause, age and '
      'length; a finished run whose check failed is a failure', (tester) async {
    await pump(tester);
    final names = tester
        .widgetList<RunTile>(find.byType(RunTile))
        .map((t) => t.run.id)
        .toList();
    expect(names, ['r3', 'r1', 'r2']);
    expect(find.text('Run now · just now · running'), findsOneWidget);
    expect(find.text('Schedule · 7h ago · 3m 12s'), findsOneWidget);
    expect(find.text('Failed · 1'), findsOneWidget);
    expect(find.text('Running · 1'), findsOneWidget);
  });

  testWidgets('filters: failed, running, one automation', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Failed · 1'));
    await tester.pumpAndSettle();
    expect(find.byType(RunTile), findsOneWidget);
    expect(tester.widget<RunTile>(find.byType(RunTile)).run.id, 'r2');

    await tester.tap(find.text('Running · 1'));
    await tester.pumpAndSettle();
    expect(tester.widget<RunTile>(find.byType(RunTile)).run.id, 'r3');

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    container.read(runsFilterProvider.notifier).only('review');
    await tester.pumpAndSettle();
    expect(find.byType(RunTile), findsOneWidget);
    expect(find.text('Review'), findsWidgets);
  });

  testWidgets('a run opens to its steps and what can be done about it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.text('Schedule · 1d ago · 3m 12s'));
    await tester.pumpAndSettle();
    expect(find.text('reason of r2'), findsOneWidget);
    expect(find.textContaining('Fail · tests'), findsOneWidget);
    expect(find.text('Sent to the session: "fix the tests"'), findsOneWidget);
    expect(find.byKey(const ValueKey('run-open-session')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-again')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-cancel')), findsNothing);

    await tester.tap(find.text('Run now · just now · running'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('run-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel run').last);
    await tester.pumpAndSettle();
    expect(server.automationRows.runs['r3']!.state, AutomationRunState.failed);
  });

  testWidgets('older runs page in past the copy, never capped', (tester) async {
    for (var i = 0; i < 60; i++) {
      server.automationRows.insertRun(
        run('old$i', 'nightly', ago: Duration(days: 2, minutes: i)),
      );
    }
    await pump(tester);
    expect(container.read(shownRunsProvider), hasLength(63));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('runs-older')),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const ValueKey('runs-older')));
    await tester.pumpAndSettle();
    // The page asked for the runs before the oldest shown; there are none.
    expect(container.read(olderRunsProvider).more, isFalse);
    expect(find.byKey(const ValueKey('runs-older')), findsNothing);
  });

  testWidgets('it fits a phone, a desktop and large text', (tester) async {
    for (final size in const [
      Size(360, 740),
      Size(390, 844),
      Size(1440, 900),
    ]) {
      await pump(tester, size: size);
      expect(tester.takeException(), isNull, reason: '$size');
    }
    await pump(tester, size: const Size(390, 844), textScale: 1.6);
    expect(tester.takeException(), isNull);
  });
}
