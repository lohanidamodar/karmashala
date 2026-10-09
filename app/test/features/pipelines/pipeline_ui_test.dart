import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/pipelines/application/pipelines_controller.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_editor.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_card.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_detail.dart';
import 'package:karmashala/src/features/pipelines/presentation/pipeline_run_dialog.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_core/verdicts.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The dashboard's pipeline card, its hand-off at an approval gate, the run
/// detail, the editor and the run dialog — at a phone's 360 px, at text
/// scale 1.6, and on a desktop.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 9, 12);
  final threeStages = kPipelineTemplates.first;

  PipelineRun waitingRun() => PipelineRun(
    id: 'r1',
    definition: threeStages,
    repositoryId: 'r1',
    input: 'Add a badge to the cart icon',
    state: PipelineRunState.waiting,
    byPerson: true,
    createdAt: now.subtract(const Duration(minutes: 5)),
    updatedAt: now,
    records: [
      PipelineStageRecord(
        stageIndex: 0,
        role: 'Plan',
        attempt: 1,
        state: PipelineStageState.approval,
        sessionId: 's-plan',
        answer: 'Plan: a badge, then a test.',
        artifacts: const [PipelineArtifactRef(id: 'a1', title: 'spec.md')],
        startedAt: now.subtract(const Duration(minutes: 4)),
        finishedAt: now.subtract(const Duration(minutes: 1)),
      ),
    ],
  );

  PipelineRun failedRun() => PipelineRun(
    id: 'r2',
    definition: kPipelineTemplates[1],
    repositoryId: 'r1',
    input: 'Fix the flaky test',
    state: PipelineRunState.failed,
    reason: 'Test still fails after 2 loop-backs.',
    createdAt: now.subtract(const Duration(minutes: 30)),
    updatedAt: now,
    finishedAt: now,
    records: [
      PipelineStageRecord(
        stageIndex: 0,
        role: 'Implement',
        attempt: 1,
        state: PipelineStageState.done,
        sessionId: 's-impl',
        answer: 'changed it',
        worktreePath: '/wt/s-impl',
        branch: 'session/s-impl',
        startedAt: now.subtract(const Duration(minutes: 20)),
        finishedAt: now.subtract(const Duration(minutes: 10)),
      ),
      PipelineStageRecord(
        stageIndex: 1,
        role: 'Test',
        attempt: 1,
        state: PipelineStageState.failed,
        sessionId: 's-test',
        answer: 'VERDICT: FAIL',
        reason: 'Checks failed.',
        check: PipelineCheckRecord(
          verdict: VerificationVerdict.fail,
          summary: 'Pipeline check: exit 1',
          checkedAt: now,
          verificationRunId: 'v1',
        ),
        startedAt: now.subtract(const Duration(minutes: 9)),
        finishedAt: now,
      ),
    ],
  );

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    server.pipelineRows
      ..putRun(waitingRun())
      ..putRun(failedRun());
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
    WidgetTester tester,
    Widget body, {
    Size size = const Size(1440, 1200),
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
            child: Scaffold(body: body),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const sizes = [
    (Size(360, 1600), 1.0),
    (Size(1440, 1200), 1.0),
    (Size(360, 2400), 1.6),
  ];

  testWidgets('the card draws every stage, across on a desktop and down on '
      'a phone, without overflow', (tester) async {
    for (final (size, scale) in sizes) {
      await pump(tester, const OverviewPipelines(), size: size, textScale: scale);
      expect(tester.takeException(), isNull, reason: '$size $scale');
      expect(find.byKey(const ValueKey('pipeline-card:r1')), findsOneWidget);
      expect(find.byKey(const ValueKey('pipeline-card:r2')), findsOneWidget);
      expect(
        find.byKey(
          ValueKey(
            size.width < 600
                ? 'pipeline-flow-vertical:r1'
                : 'pipeline-flow-horizontal:r1',
          ),
        ),
        findsOneWidget,
        reason: '$size',
      );
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(ValueKey('pipeline-stage:r1:$i')), findsOneWidget);
      }
      expect(find.text('Waiting for you at Plan'), findsOneWidget);
      expect(find.text('Failed at Test'), findsOneWidget);
    }
  });

  testWidgets('the hand-off at a gate is edited and approved', (tester) async {
    await pump(tester, const OverviewPipelines());
    final field = find.byKey(const ValueKey('pipeline-handoff-text:r1'));
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Plan: a badge, then a test.',
    );
    expect(find.textContaining('spec.md'), findsOneWidget);
    await tester.enterText(field, 'Plan: a badge only.');
    await tester.tap(find.byKey(const ValueKey('pipeline-approve:r1')));
    await tester.pumpAndSettle();
    expect(server.pipelineRows.acts, ['approve r1 Plan: a badge only.']);
    expect(container.read(pipelinesProvider).runs['r1']!.state,
        PipelineRunState.running);
  });

  testWidgets('a failed stage is retried or skipped from its card',
      (tester) async {
    await pump(tester, const OverviewPipelines());
    expect(find.text('Test still fails after 2 loop-backs.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pipeline-retry:r2')));
    await tester.pumpAndSettle();
    expect(server.pipelineRows.acts, ['retry r2']);
    // Running again: Stop, no Retry.
    expect(find.byKey(const ValueKey('pipeline-retry:r2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pipeline-stop:r2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pipeline-skip:r2')));
    await tester.pumpAndSettle();
    expect(server.pipelineRows.acts, ['retry r2', 'stop r2', 'skip r2']);
  });

  testWidgets('the run detail shows each stage, its checks and its session',
      (tester) async {
    for (final (size, scale) in sizes) {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showPipelineRunDetail(context, 'r2'),
            child: const Text('open'),
          ),
        ),
        size: size,
        textScale: scale,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size $scale');
      expect(find.byKey(const ValueKey('pipeline-record:1:1')), findsOneWidget);
      expect(find.text('Checks failed'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pipeline-open-session:s-test')),
        findsOneWidget,
      );
      expect(find.textContaining('session/s-impl'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the editor saves a copy of a template, refusing what cannot '
      'run, at every size', (tester) async {
    for (final (size, scale) in sizes) {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showPipelineEditor(context, initial: threeStages),
            child: const Text('edit'),
          ),
        ),
        size: size,
        textScale: scale,
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size $scale');
      expect(
        find.byKey(const ValueKey('pipeline-editor-stage:2')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    }

    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showPipelineEditor(context, initial: threeStages),
          child: const Text('edit'),
        ),
      ),
    );
    await tester.tap(find.text('edit'));
    await tester.pumpAndSettle();
    final name = find.byKey(const ValueKey('pipeline-editor-name'));
    expect(
      tester.widget<TextField>(name).controller!.text,
      'Plan → Implement → Review (copy)',
    );
    // Two stages with one name cannot both be addressed by a field.
    await tester.enterText(
      find.byKey(const ValueKey('pipeline-editor-role:1')),
      'Plan',
    );
    await tester.tap(find.byKey(const ValueKey('pipeline-editor-save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('pipeline-editor-error')),
      findsOneWidget,
    );
    expect(server.pipelineRows.saved, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('pipeline-editor-role:1')),
      'Implement',
    );
    await tester.tap(find.byKey(const ValueKey('pipeline-editor-fields:1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('{{plan.answer}}'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('pipeline-editor-save')),
    );
    await tester.tap(find.byKey(const ValueKey('pipeline-editor-save')));
    await tester.pumpAndSettle();
    final saved = server.pipelineRows.saved.values.single;
    expect(saved.builtIn, isFalse);
    expect(saved.name, 'Plan → Implement → Review (copy)');
    expect(saved.stages[1].instruction, contains('{{plan.answer}}'));
  });

  testWidgets('a person runs a pipeline from the dialog', (tester) async {
    for (final (size, scale) in sizes) {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showRunPipeline(context),
            child: const Text('run'),
          ),
        ),
        size: size,
        textScale: scale,
      );
      await tester.tap(find.text('run'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$size $scale');
      await tester.pumpWidget(const SizedBox());
    }
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showRunPipeline(context),
          child: const Text('run'),
        ),
      ),
    );
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    final start = find.byKey(const ValueKey('pipeline-run-start'));
    expect(tester.widget<FilledButton>(start).onPressed, isNull,
        reason: 'nothing to do yet');
    await tester.enterText(
      find.byKey(const ValueKey('pipeline-run-input')),
      'Add dark mode',
    );
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(server.pipelineRows.acts, ['start Add dark mode']);
    expect(find.byType(RunPipelineDialog), findsNothing);
  });

  test('the dashboard keeps an ended run for an hour', () {
    final ended = failedRun();
    final state = PipelinesState(runs: {'r1': waitingRun(), 'r2': ended});
    expect(dashboardPipelineRuns(state, now: now).map((r) => r.id),
        containsAll(['r1', 'r2']));
    expect(
      dashboardPipelineRuns(
        state,
        now: now.add(const Duration(hours: 2)),
      ).map((r) => r.id),
      ['r1'],
    );
  });
}
