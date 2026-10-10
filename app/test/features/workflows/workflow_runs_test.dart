import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/workflows/application/workflow_runs.dart';
import 'package:karmashala/src/features/workflows/application/workflows_state.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_core/verdicts.dart';

/// How an automation run and a pipeline run read as one kind of row, and
/// what the Workflows glance counts.
void main() {
  final now = DateTime.utc(2026, 10, 10, 12);

  final automation = Automation(
    id: 'auto1',
    repositoryId: 'r1',
    name: 'Nightly',
    schedule: const AutomationSchedule.cron('0 2 * * *'),
    agentInstallationId: 'a1',
    prompt: 'x',
    permissionMode: null,
    enabled: true,
    armedAt: now,
  );

  AutomationRun automationRun({
    AutomationRunState state = AutomationRunState.finished,
    List<AutomationStepResult> steps = const [],
    AutomationRunCause? cause,
  }) => AutomationRun(
    id: 'run1',
    automationId: 'auto1',
    scheduledFor: now,
    firedAt: now.subtract(const Duration(minutes: 5)),
    state: state,
    reason: 'r',
    finishedAt: state.isLive ? null : now,
    stepResults: steps,
    startedBy: cause,
  );

  PipelineRun pipelineRun(
    PipelineRunState state, {
    bool byPerson = false,
    String? session,
    PipelineRunAutomation? by,
    DateTime? at,
  }) => PipelineRun(
    id: 'p-${state.name}',
    definition: kPipelineTemplates.first,
    repositoryId: 'r2',
    input: 'x',
    state: state,
    byPerson: byPerson,
    startedBySessionId: session,
    automation: by,
    createdAt: at ?? now,
    updatedAt: at ?? now,
    records: const [
      PipelineStageRecord(
        stageIndex: 1,
        role: 'Implement',
        attempt: 1,
        state: PipelineStageState.running,
      ),
    ],
  );

  group('an automation run', () {
    test('its status, by its state, checks and steps', () {
      WorkflowRunStatus of(
        AutomationRun run, [
        List<AutomationCheckVerdict> checks = const [],
      ]) =>
          automationRunRow(run, automation: automation, checks: checks).status;

      expect(
        of(automationRun(state: AutomationRunState.queued)),
        WorkflowRunStatus.running,
      );
      expect(of(automationRun()), WorkflowRunStatus.done);
      expect(
        of(automationRun(state: AutomationRunState.missed)),
        WorkflowRunStatus.failed,
      );
      expect(
        of(automationRun(), [
          AutomationCheckVerdict(
            runId: 'run1',
            ordinal: 1,
            name: 'tests',
            command: const ['x'],
            verdict: VerificationVerdict.fail,
            reason: '',
            checkedAt: now,
          ),
        ]),
        WorkflowRunStatus.failed,
      );
      final waiting = automationRunRow(
        automationRun(
          steps: [
            AutomationStepResult(
              kind: AutomationStepKind.pipeline,
              outcome: AutomationStepOutcome.waiting,
              detail: '',
              at: now,
              pipelineRunId: 'p1',
            ),
          ],
        ),
        automation: automation,
        checks: const [],
      );
      expect(waiting.status, WorkflowRunStatus.running);
      expect(waiting.statusWords, 'Waiting on pipeline');
      expect(waiting.finishedAt, now);
    });

    test('who started it, its project and its session', () {
      final scheduled = automationRunRow(
        automationRun(),
        automation: automation,
        checks: const [],
      );
      expect(scheduled.startedBy, 'Schedule');
      expect(scheduled.starter, WorkflowStarter.automation);
      expect(scheduled.repositoryId, 'r1');
      expect(scheduled.ownerId, 'auto1');
      final byHand = automationRunRow(
        automationRun(cause: AutomationRunCause.runNow),
        automation: automation,
        checks: const [],
      );
      expect(byHand.startedBy, 'You');
      expect(byHand.starter, WorkflowStarter.person);
    });
  });

  group('a pipeline run', () {
    test('its status, stage and starter', () {
      expect(
        pipelineRunRow(pipelineRun(PipelineRunState.waiting)).status,
        WorkflowRunStatus.waitingOnYou,
      );
      expect(
        pipelineRunRow(pipelineRun(PipelineRunState.stopped)).status,
        WorkflowRunStatus.stopped,
      );
      final row = pipelineRunRow(
        pipelineRun(
          PipelineRunState.running,
          by: const PipelineRunAutomation(
            automationId: 'auto1',
            runId: 'run1',
            name: 'Nightly',
          ),
        ),
      );
      expect(row.kind, WorkflowRunKind.pipeline);
      expect(row.stage, 'Implement');
      expect(row.startedBy, 'Nightly');
      expect(row.starter, WorkflowStarter.automation);
      expect(row.finishedAt, isNull);
      expect(
        pipelineRunRow(
          pipelineRun(PipelineRunState.running, byPerson: true),
        ).startedBy,
        'You',
      );
      expect(
        pipelineRunRow(
          pipelineRun(PipelineRunState.running, session: 's1'),
        ).startedBy,
        'An agent',
      );
    });
  });

  test('a filter keeps what it names, and null is every choice', () {
    final rows = [
      automationRunRow(automationRun(), automation: automation, checks: []),
      pipelineRunRow(pipelineRun(PipelineRunState.failed)),
    ];
    expect(const WorkflowRunsFilter().count, 0);
    const pipelinesOnly = WorkflowRunsFilter(kinds: {WorkflowRunKind.pipeline});
    expect(rows.where(pipelinesOnly.shows), [rows.last]);
    const inR1 = WorkflowRunsFilter(projects: {'r1'});
    expect(rows.where(inR1.shows), [rows.first]);
    const failing = WorkflowRunsFilter(
      statuses: {WorkflowRunStatus.failed},
      kinds: {WorkflowRunKind.automation},
    );
    expect(failing.count, 2);
    expect(rows.where(failing.shows), isEmpty);
  });

  test(
    'the glance counts today\'s runs, those waiting and today\'s failures',
    () {
      final yesterday = now.subtract(const Duration(days: 2));
      final rows = [
        pipelineRunRow(pipelineRun(PipelineRunState.waiting)),
        pipelineRunRow(pipelineRun(PipelineRunState.failed)),
        pipelineRunRow(pipelineRun(PipelineRunState.failed, at: yesterday)),
        pipelineRunRow(pipelineRun(PipelineRunState.finished, at: yesterday)),
      ];
      final facts = workflowsGlanceFacts(rows, now: now);
      expect(facts.today, 2);
      expect(facts.waiting, 1);
      expect(facts.failed, 1);
      expect(facts.newest, rows.first);
      expect(workflowsGlanceFacts(const [], now: now).newest, isNull);
    },
  );

  test('a pipeline with no ended run has no rate, not 0%', () {
    expect(const PipelineRunStats().rate, isNull);
    expect(const PipelineRunStats(ended: 4, finished: 3).rate, 0.75);
  });
}
