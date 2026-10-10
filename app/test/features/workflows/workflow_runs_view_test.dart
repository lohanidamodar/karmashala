import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_runs_page.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_card.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_detail.dart';
import 'package:karmashala/src/features/workflows/application/workflow_runs.dart';
import 'package:karmashala/src/features/workflows/application/workflows_state.dart';
import 'package:karmashala/src/features/workflows/presentation/workflow_runs_view.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_verification/verification.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// **Runs**: every automation run and pipeline run in one list, newest first,
/// filtered by state, kind and project, each opening the detail its kind
/// already had.
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

  final gated = PipelineRun(
    id: 'p1',
    definition: kPipelineTemplates.first,
    repositoryId: 'r1',
    input: 'Fix the failing tests',
    state: PipelineRunState.waiting,
    automation: const PipelineRunAutomation(
      automationId: 'nightly',
      runId: 'r1',
      name: 'Nightly',
    ),
    createdAt: now.subtract(const Duration(minutes: 10)),
    updatedAt: now,
    records: [
      PipelineStageRecord(
        stageIndex: 0,
        role: 'Plan',
        attempt: 1,
        state: PipelineStageState.approval,
        sessionId: 's-plan',
        answer: 'The plan',
        startedAt: now.subtract(const Duration(minutes: 9)),
        finishedAt: now.subtract(const Duration(minutes: 1)),
      ),
    ],
  );

  final failed = PipelineRun(
    id: 'p2',
    definition: kPipelineTemplates[1],
    repositoryId: 'r1',
    input: 'Add a badge',
    state: PipelineRunState.failed,
    byPerson: true,
    reason: 'The checks failed.',
    createdAt: now.subtract(const Duration(hours: 2)),
    updatedAt: now.subtract(const Duration(hours: 1)),
    finishedAt: now.subtract(const Duration(hours: 1)),
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
      ..insertRun(
        run(
          'r1',
          'nightly',
          ago: const Duration(hours: 7),
          steps: [
            AutomationStepResult(
              kind: AutomationStepKind.pipeline,
              outcome: AutomationStepOutcome.waiting,
              detail:
                  'Started "Plan → Implement → Review"; waiting on the '
                  'pipeline.',
              at: now,
              pipelineRunId: 'p1',
            ),
          ],
        ),
      )
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
    server.pipelineRows
      ..putRun(gated)
      ..putRun(failed);
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
            child: const Scaffold(body: WorkflowRunsView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> shown(WidgetTester tester) => [
    for (final tile in tester.widgetList<WorkflowRunTile>(
      find.byType(WorkflowRunTile),
    ))
      '${tile.row.ref}',
  ];

  Finder row(WorkflowRunKind kind, String id) =>
      find.byKey(ValueKey('workflow-run:${WorkflowRunRef(kind, id)}'));

  testWidgets('both kinds in one list, newest first, each with its status, '
      'stage, who started it, when, how long, cost and project', (
    tester,
  ) async {
    await pump(tester);
    expect(shown(tester), [
      'automation:r3',
      'pipeline:p1',
      'pipeline:p2',
      'automation:r1',
      'automation:r2',
    ]);
    for (final column in const [
      'Run',
      'Status',
      'Started by',
      'When',
      'Took',
      'Cost',
      'Project',
    ]) {
      expect(find.text(column.toUpperCase()), findsOneWidget);
    }
    // A run started by hand, one by an automation's pipeline step, and one
    // whose own pipeline step still runs.
    final r3 = find.descendant(
      of: row(WorkflowRunKind.automation, 'r3'),
      matching: find.text('You'),
    );
    expect(r3, findsOneWidget);
    final p1 = row(WorkflowRunKind.pipeline, 'p1');
    expect(
      find.descendant(of: p1, matching: find.text('Waiting on you')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: p1, matching: find.text('Nightly')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('workflow-run-stage:pipeline:p1')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row(WorkflowRunKind.automation, 'r1'),
        matching: find.text('Waiting on pipeline'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row(WorkflowRunKind.automation, 'r2'),
        matching: find.text('Failed'),
      ),
      findsOneWidget,
    );
    expect(find.text('3m 12s'), findsNWidgets(2));
    expect(find.text('app'), findsNWidgets(5));
    // Nobody reported spending: a dash, never $0.00.
    expect(find.text('—'), findsNWidgets(5));
  });

  testWidgets('filters: state, kind and project, from the funnel', (
    tester,
  ) async {
    await pump(tester);
    final filters = container.read(workflowRunsFilterProvider.notifier);
    filters.setStatuses({WorkflowRunStatus.failed});
    await tester.pumpAndSettle();
    expect(shown(tester), ['pipeline:p2', 'automation:r2']);

    filters
      ..setStatuses(null)
      ..setKinds({WorkflowRunKind.pipeline});
    await tester.pumpAndSettle();
    expect(shown(tester), ['pipeline:p1', 'pipeline:p2']);

    filters
      ..setKinds(null)
      ..setProjects({'elsewhere'});
    await tester.pumpAndSettle();
    expect(find.text('No runs match.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workflow-runs-clear')));
    await tester.pumpAndSettle();
    expect(shown(tester), hasLength(5));

    // The same, through the checklist.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(appBar: _Bar(), body: WorkflowRunsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workflow-runs-filter')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('workflow-runs-filter-panel')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('runs-kind-only:automation')));
    await tester.pumpAndSettle();
    expect(container.read(workflowRunsFilterProvider).kinds, {
      WorkflowRunKind.automation,
    });
  });

  testWidgets('one automation\'s runs, from its card', (tester) async {
    await pump(tester);
    container.read(runsFilterProvider.notifier).only('review');
    await tester.pumpAndSettle();
    expect(shown(tester), ['automation:r3']);
    await tester.tap(find.byKey(const ValueKey('runs-automation-chip')));
    container.read(runsFilterProvider.notifier).only(null);
    await tester.pumpAndSettle();
    expect(shown(tester), hasLength(5));
  });

  testWidgets('an automation run opens beside the list, to its steps and '
      'what can be done about it', (tester) async {
    await pump(tester);
    await tester.tap(row(WorkflowRunKind.automation, 'r2'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workflow-run-detail')), findsOneWidget);
    expect(find.byKey(const ValueKey('workflow-runs-list')), findsOneWidget);
    expect(find.text('reason of r2'), findsOneWidget);
    expect(find.textContaining('Fail · tests'), findsOneWidget);
    expect(find.text('Sent to the session: "fix the tests"'), findsOneWidget);
    expect(find.byKey(const ValueKey('run-open-session')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-again')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-cancel')), findsNothing);
    expect(find.text('not recorded'), findsOneWidget);

    await tester.tap(row(WorkflowRunKind.automation, 'r3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('run-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel run').last);
    await tester.pumpAndSettle();
    expect(server.automationRows.runs['r3']!.state, AutomationRunState.failed);
  });

  testWidgets('its pipeline step says the pipeline still runs', (tester) async {
    await pump(tester);
    await tester.tap(row(WorkflowRunKind.automation, 'r1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('waiting on the pipeline'), findsOneWidget);
    expect(find.text('Run a pipeline'), findsOneWidget);
  });

  testWidgets('a pipeline run opens its card and stages, its gate in reach', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(row(WorkflowRunKind.pipeline, 'p1'));
    await tester.pumpAndSettle();
    expect(find.byType(PipelineRunDetail), findsOneWidget);
    expect(find.byType(PipelineRunCard), findsOneWidget);
    expect(find.byKey(const ValueKey('pipeline-record:0:1')), findsOneWidget);
    expect(find.byKey(const ValueKey('pipeline-approve:p1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pipeline-approve:p1')));
    await tester.pumpAndSettle();
    expect(server.pipelineRows.acts.single, startsWith('approve p1'));

    await tester.tap(find.byKey(const ValueKey('workflow-run-detail-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workflow-run-detail')), findsNothing);
  });

  testWidgets('on a phone the detail is the page, with a way back', (
    tester,
  ) async {
    await pump(tester, size: const Size(390, 844));
    expect(find.text('RUN'), findsNothing);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('workflow-run-meta:automation:r3')),
          )
          .data,
      'You · just now · 0s · app',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('workflow-run-meta:pipeline:p1')),
          )
          .data,
      'Plan · Nightly · 10m ago · 10m 0s · app',
    );
    await tester.tap(row(WorkflowRunKind.pipeline, 'p1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workflow-runs-list')), findsNothing);
    expect(find.byKey(const ValueKey('workflow-run-detail')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workflow-run-detail-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workflow-runs-list')), findsOneWidget);
  });

  testWidgets('older automation runs page in past the copy', (tester) async {
    for (var i = 0; i < 60; i++) {
      server.automationRows.insertRun(
        run('old$i', 'nightly', ago: Duration(days: 2, minutes: i)),
      );
    }
    await pump(tester);
    expect(container.read(shownWorkflowRunRowsProvider), hasLength(65));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('runs-older')),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('runs-older')));
    await tester.pumpAndSettle();
    expect(container.read(olderRunsProvider).more, isFalse);
    expect(find.byKey(const ValueKey('runs-older')), findsNothing);
  });

  for (final (size, scale) in const [
    (Size(360, 740), 1.0),
    (Size(360, 740), 1.6),
    (Size(412, 915), 1.0),
    (Size(412, 915), 1.6),
    (Size(1440, 900), 1.0),
    (Size(1440, 900), 1.6),
  ]) {
    testWidgets('the list and both details fit ${size.width.toInt()} px at '
        '$scale', (tester) async {
      await pump(tester, size: size, textScale: scale);
      expect(tester.takeException(), isNull, reason: 'list');
      for (final ref in const [
        WorkflowRunRef(WorkflowRunKind.automation, 'r2'),
        WorkflowRunRef(WorkflowRunKind.pipeline, 'p1'),
      ]) {
        container.read(selectedWorkflowRunProvider.notifier).select(ref);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$ref');
      }
    });
  }

  testWidgets('a check over code that changed since says it is stale', (
    tester,
  ) async {
    const head = 'cccccccccccccccccccccccccccccccccccccccc';
    server.verificationRows.insertRun(
      VerificationRun(
        id: 'vr1',
        title: 'tests',
        target: const VerificationTarget.change(),
        startedAt: now,
        finishedAt: now,
        verdict: VerificationVerdict.pass,
        artifactDirectory: 'C:/art/vr1',
        identity: const CodeIdentity(
          environmentId: 'windows',
          path: '/src/demo',
          head: head,
          tree: '',
          dirty: {},
        ),
      ),
    );
    server.gitWork.codeFreshness[head] = const CodeFreshness.stale(
      'Uncommitted files changed since this ran.',
      filesChanged: 2,
    );
    server.automationRows.insertRunCheck(
      AutomationCheckVerdict(
        runId: 'r1',
        ordinal: 1,
        name: 'analyze',
        command: const ['dart', 'analyze'],
        verdict: VerificationVerdict.pass,
        reason: 'passed',
        checkedAt: now,
        verificationRunId: 'vr1',
      ),
    );
    await pump(tester);
    await tester.tap(row(WorkflowRunKind.automation, 'r1'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Pass · stale (2 files changed since) · analyze'),
      findsOneWidget,
    );
  });
}

/// The page's header, holding the filter control as Workflows' header does.
class _Bar extends StatelessWidget implements PreferredSizeWidget {
  const _Bar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) =>
      AppBar(actions: const [WorkflowRunsFilterButton()]);
}
