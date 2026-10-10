import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'pipeline_fakes.dart';
import 'service_fixtures.dart';

/// Starts nothing: records what it was asked, and answers a run id.
class _Starter implements StepPipelineStarter {
  final calls =
      <
        ({
          String automationRun,
          String pipelineId,
          String repositoryId,
          String input,
        })
      >[];
  String? refuse;

  @override
  Future<StepPipelineStarted> start(
    Automation automation,
    AutomationRun run, {
    required String pipelineId,
    required String repositoryId,
    required String input,
  }) async {
    if (refuse case final why?) throw StateError(why);
    calls.add((
      automationRun: run.id,
      pipelineId: pipelineId,
      repositoryId: repositoryId,
      input: input,
    ));
    return const StepPipelineStarted(runId: 'p1', name: 'Fix loop');
  }
}

/// "Run a pipeline": the step starts a pipeline run attributed to the
/// automation, as background work, and the automation run ends waiting on it
/// while the pipeline carries on and reports back.
void main() {
  group('the step', () {
    test('needs a pipeline and an input', () {
      expect(
        const AutomationStep(
          kind: AutomationStepKind.pipeline,
          text: 'Fix it',
        ).refusal,
        contains('Pick the pipeline'),
      );
      expect(
        const AutomationStep(
          kind: AutomationStepKind.pipeline,
          pipelineId: 'builtin:implement-test-fix',
        ).refusal,
        contains('{{input}}'),
      );
      expect(
        const AutomationStep(
          kind: AutomationStepKind.pipeline,
          pipelineId: 'builtin:implement-test-fix',
          text: 'Fix {{steps.check.output}}',
        ).refusal,
        isNull,
      );
    });

    test('its pipeline and checkout round-trip, in step order', () {
      final steps = AutomationSteps(const [
        AutomationStep(kind: AutomationStepKind.notify, text: 'hi'),
        AutomationStep(
          kind: AutomationStepKind.pipeline,
          when: AutomationStepWhen.failure,
          pipelineId: 'builtin:implement-test-fix',
          repositoryId: 'repo2',
          text: 'Fix it',
        ),
        AutomationStep(kind: AutomationStepKind.command, text: 'make'),
      ]);
      expect(AutomationSteps.fromColumn(steps.toColumn()), steps);
      expect(steps.after.map((s) => s.kind), [
        AutomationStepKind.command,
        AutomationStepKind.pipeline,
        AutomationStepKind.notify,
      ]);
    });

    test('a waiting result and its pipeline run round-trip', () {
      final result = AutomationStepResult(
        kind: AutomationStepKind.pipeline,
        outcome: AutomationStepOutcome.waiting,
        detail: 'waiting',
        at: DateTime.utc(2026, 10, 10),
        pipelineRunId: 'p1',
      );
      expect(AutomationStepResult.fromJson(result.toJson()), result);
    });
  });

  group('after a run', () {
    late AppDatabase db;
    late AutomationDao dao;
    late _Starter starter;
    late List<String> notified;

    AutomationFollowUps followUps() => AutomationFollowUps(
      automations: dao,
      resumes: ScheduledResumeDao(db),
      repositoryName: (_) => 'repo',
      notify: (automation, run, text, {required failed}) => notified.add(text),
      now: () => fixtureTime,
      newId: () => 'id',
      pipelines: starter,
    );

    AutomationRun arm(List<AutomationStep> steps) {
      dao.insert(
        fixtureAutomation(
          armedAt: fixtureTime,
        ).copyWith(steps: AutomationSteps(steps)),
      );
      final run = AutomationRun(
        id: 'run1',
        automationId: 'auto1',
        scheduledFor: fixtureTime,
        firedAt: fixtureTime,
        state: AutomationRunState.finished,
        reason: 'The tests ran.',
      );
      dao.insertRun(run);
      return run;
    }

    setUp(() {
      db = fixtureDatabase();
      dao = AutomationDao(db);
      starter = _Starter();
      notified = [];
    });
    tearDown(() => db.close());

    test('starts the pipeline with its input filled, in the automation\'s '
        'checkout, and the run ends waiting on it', () async {
      final run = arm(const [
        AutomationStep(
          kind: AutomationStepKind.pipeline,
          when: AutomationStepWhen.always,
          pipelineId: 'builtin:implement-test-fix',
          text: '{{automation}}: {{steps.agent.output}}',
        ),
        AutomationStep(
          kind: AutomationStepKind.notify,
          when: AutomationStepWhen.always,
          text: 'pipeline {{steps.pipeline.run}}',
        ),
      ]);
      await followUps().after(run);
      final call = starter.calls.single;
      expect(call.automationRun, 'run1');
      expect(call.pipelineId, 'builtin:implement-test-fix');
      expect(
        call.repositoryId,
        fixtureAutomation(armedAt: fixtureTime).repositoryId,
      );
      expect(call.input, contains('The tests ran.'));
      final result = dao.runById('run1')!.stepResults.first;
      expect(result.kind, AutomationStepKind.pipeline);
      expect(result.outcome, AutomationStepOutcome.waiting);
      expect(result.pipelineRunId, 'p1');
      expect(result.detail, contains('waiting on the pipeline'));
      expect(notified.single, 'pipeline p1');
    });

    test('a step naming its own checkout starts it there', () async {
      final run = arm(const [
        AutomationStep(
          kind: AutomationStepKind.pipeline,
          when: AutomationStepWhen.always,
          pipelineId: 'builtin:implement-test-fix',
          repositoryId: 'elsewhere',
          text: 'Fix it',
        ),
      ]);
      await followUps().after(run);
      expect(starter.calls.single.repositoryId, 'elsewhere');
    });

    test(
      'a pipeline that cannot start fails its step, and the run with it',
      () async {
        starter.refuse = 'That checkout is not in the workspace.';
        final run = arm(const [
          AutomationStep(
            kind: AutomationStepKind.pipeline,
            when: AutomationStepWhen.always,
            pipelineId: 'builtin:implement-test-fix',
            text: 'Fix it',
          ),
          AutomationStep(
            kind: AutomationStepKind.notify,
            when: AutomationStepWhen.always,
            text: '{{run.status}}',
          ),
        ]);
        await followUps().after(run);
        final result = dao.runById('run1')!.stepResults.first;
        expect(result.outcome, AutomationStepOutcome.failed);
        expect(result.detail, contains('not in the workspace'));
        expect(notified.single, 'failed');
      },
    );

    test('the pipeline reports back onto the step as it moves', () async {
      final run = arm(const [
        AutomationStep(
          kind: AutomationStepKind.pipeline,
          when: AutomationStepWhen.always,
          pipelineId: 'builtin:implement-test-fix',
          text: 'Fix it',
        ),
      ]);
      final steps = followUps();
      await steps.after(run);
      steps.pipelineMoved(
        automationRunId: 'run1',
        pipelineRunId: 'p1',
        outcome: AutomationStepOutcome.done,
        detail: '"Fix loop" finished.',
      );
      final result = dao.runById('run1')!.stepResults.single;
      expect(result.outcome, AutomationStepOutcome.done);
      expect(result.detail, '"Fix loop" finished.');
      expect(result.pipelineRunId, 'p1');
    });
  });

  group('the pipeline side', () {
    final definition = kPipelineTemplates.firstWhere(
      (p) => p.id == 'builtin:implement-test-fix',
    );
    const automation = PipelineRunAutomation(
      automationId: 'auto1',
      runId: 'run1',
      name: 'Nightly',
    );

    test('an automation\'s run launches as background work, attributed to '
        'it', () async {
      final records = MemoryPipelineRecords();
      final launcher = FakeStageLauncher();
      final runner = PipelineRunner(
        records: records,
        launcher: launcher,
        watcher: FakeStageWatcher(),
        evidence: FakeStageEvidence(),
        now: () => DateTime.utc(2026, 10, 10, 2),
        newId: () => 'p1',
      );
      final run = runner.start(
        definition: definition,
        repositoryId: 'repo',
        input: 'Fix the failing tests',
        automation: automation,
      );
      await pumpEventQueue();
      expect(launcher.launches.single.priority, StagePriority.background);
      expect(run.startedBy, PipelineRunStarter.automation);
      final stored = PipelineRun.fromJson(records.run('p1')!.toJson());
      expect(stored.automation?.runId, 'run1');
      expect(stored.automation?.name, 'Nightly');
      expect(stored.startedBy, PipelineRunStarter.automation);
    });

    test('who started a run', () {
      PipelineRun of({
        bool person = false,
        String? session,
        PipelineRunAutomation? by,
      }) => PipelineRun(
        id: 'r',
        definition: definition,
        repositoryId: 'repo',
        input: 'x',
        state: PipelineRunState.running,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        byPerson: person,
        startedBySessionId: session,
        automation: by,
      );
      expect(of(person: true).startedBy, PipelineRunStarter.person);
      expect(of(by: automation).startedBy, PipelineRunStarter.automation);
      expect(of(session: 's1').startedBy, PipelineRunStarter.agent);
      expect(of().startedBy, PipelineRunStarter.unknown);
    });

    test('what the step reports of each state', () {
      PipelineRun at(PipelineRunState state) => PipelineRun(
        id: 'p1',
        definition: definition,
        repositoryId: 'repo',
        input: 'x',
        state: state,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        records: const [
          PipelineStageRecord(
            stageIndex: 1,
            role: 'Tester',
            attempt: 1,
            state: PipelineStageState.running,
          ),
        ],
        reason: 'The checks failed.',
      );
      expect(
        pipelineStepReport(at(PipelineRunState.running)).outcome,
        AutomationStepOutcome.waiting,
      );
      final gate = pipelineStepReport(at(PipelineRunState.waiting));
      expect(gate.outcome, AutomationStepOutcome.waiting);
      expect(gate.detail, contains('approval at Tester'));
      expect(
        pipelineStepReport(at(PipelineRunState.finished)).outcome,
        AutomationStepOutcome.done,
      );
      final failed = pipelineStepReport(at(PipelineRunState.failed));
      expect(failed.outcome, AutomationStepOutcome.failed);
      expect(failed.detail, contains('The checks failed.'));
      expect(
        pipelineStepReport(at(PipelineRunState.stopped)).outcome,
        AutomationStepOutcome.failed,
      );
    });
  });
}
