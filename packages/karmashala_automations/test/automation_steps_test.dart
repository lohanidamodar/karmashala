import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service/service_fixtures.dart';

/// One automation: a trigger, the agent, and the steps after it.
void main() {
  group('the steps', () {
    test('keep their fixed order and one of each kind', () {
      final steps = AutomationSteps(const [
        AutomationStep(kind: AutomationStepKind.notify),
        AutomationStep(kind: AutomationStepKind.check),
        AutomationStep(kind: AutomationStepKind.tell, text: 'first'),
        AutomationStep(kind: AutomationStepKind.tell, text: 'second'),
      ]);
      expect(steps.after.map((s) => s.kind), [
        AutomationStepKind.check,
        AutomationStepKind.tell,
        AutomationStepKind.notify,
      ]);
      expect(steps.of(AutomationStepKind.tell)!.text, 'second');
    });

    test('the standard steps store as nothing, so old rows read the same', () {
      expect(AutomationSteps.standard.toColumn(), isNull);
      expect(AutomationSteps.fromColumn(null), AutomationSteps.standard);
      expect(AutomationSteps.fromColumn('not json'), AutomationSteps.standard);
      expect(AutomationSteps.standard.checks, isTrue);
    });

    test('a step from a newer build is left out, not misread', () {
      final steps = AutomationSteps.fromColumn(
        '[{"kind":"check","when":"success"},{"kind":"run","when":"always"}]',
      );
      expect(steps, AutomationSteps.standard);
    });

    test('round-trip through the column and the wire', () {
      final steps = AutomationSteps(const [
        AutomationStep(
          kind: AutomationStepKind.tell,
          when: AutomationStepWhen.failure,
          text: 'Fix {{steps.check.output}}',
        ),
        AutomationStep(
          kind: AutomationStepKind.notify,
          when: AutomationStepWhen.always,
        ),
      ]);
      expect(AutomationSteps.fromColumn(steps.toColumn()), steps);
      expect(AutomationSteps.fromJson(steps.toJson()), steps);
      expect(steps.checks, isFalse);
    });

    test('variables fill, and an unknown one shows as typed', () {
      expect(
        fillStepText('{{project}}: {{run.status}} {{nope}}', {
          'project': 'app',
          'run.status': 'failed',
        }),
        'app: failed {{nope}}',
      );
    });

    test('a sender that names no steps reads as unstated', () {
      final json = automationToJson(fixtureAutomation(armedAt: fixtureTime))
        ..remove('steps');
      final read = automationFromJson(json);
      expect(read.steps.stated, isFalse);
      expect(read.steps.checks, isTrue);
    });

    test('an older webhook sender still carries its model', () {
      final json = automationToJson(fixtureAutomation(armedAt: fixtureTime))
        ..remove('modelId')
        ..remove('worktree')
        ..['webhook'] = {'hookId': 'h', 'modelId': 'opus', 'worktree': true};
      final read = automationFromJson(json);
      expect(read.modelId, 'opus');
      expect(read.worktree, isTrue);
    });
  });

  group('the store', () {
    late AppDatabase db;
    late AutomationDao dao;

    setUp(() {
      db = fixtureDatabase();
      dao = AutomationDao(db);
    });
    tearDown(() => db.close());

    test('model, worktree and steps round-trip for any kind', () {
      final steps = AutomationSteps(const [
        AutomationStep(kind: AutomationStepKind.check),
        AutomationStep(
          kind: AutomationStepKind.notify,
          when: AutomationStepWhen.failure,
          text: '{{automation}} failed',
        ),
      ]);
      dao.insert(
        fixtureAutomation(
          armedAt: fixtureTime,
        ).copyWith(modelId: 'sonnet', worktree: true, steps: steps),
      );
      final read = dao.getById('auto1')!;
      expect(read.modelId, 'sonnet');
      expect(read.worktree, isTrue);
      expect(read.steps, steps);
    });

    test('a run keeps what started it and what its steps did', () {
      dao.insert(fixtureAutomation(armedAt: fixtureTime));
      final result = AutomationStepResult(
        kind: AutomationStepKind.notify,
        outcome: AutomationStepOutcome.done,
        detail: 'Notified',
        at: fixtureTime,
      );
      dao.insertRun(
        AutomationRun(
          id: 'run1',
          automationId: 'auto1',
          scheduledFor: fixtureTime,
          firedAt: fixtureTime,
          state: AutomationRunState.running,
          reason: '',
          startedBy: AutomationRunCause.runNow,
        ),
      );
      dao.updateRun(
        dao
            .runById('run1')!
            .copyWith(
              state: AutomationRunState.finished,
              stepResults: [result],
            ),
      );
      final read = dao.runById('run1')!;
      expect(read.startedBy, AutomationRunCause.runNow);
      expect(read.stepResults, [result]);
      expect(automationRunFromJson(automationRunToJson(read)).stepResults, [
        result,
      ]);
    });
  });

  group('the steps after a run', () {
    late AppDatabase db;
    late AutomationDao dao;
    late ScheduledResumeDao resumes;
    late List<({String text, bool failed})> notified;
    var ids = 0;

    AutomationFollowUps followUps() => AutomationFollowUps(
      automations: dao,
      resumes: resumes,
      repositoryName: (_) => 'repo',
      notify: (automation, run, text, {required failed}) =>
          notified.add((text: text, failed: failed)),
      now: () => fixtureTime,
      newId: () => 'id${ids++}',
    );

    void arm(AutomationSteps steps) => dao.insert(
      fixtureAutomation(armedAt: fixtureTime).copyWith(steps: steps),
    );

    AutomationRun settled({
      AutomationRunState state = AutomationRunState.finished,
      String? sessionId = 's1',
    }) {
      final run = AutomationRun(
        id: 'run1',
        automationId: 'auto1',
        scheduledFor: fixtureTime,
        firedAt: fixtureTime,
        state: state,
        reason: 'The agent this run started finished.',
        sessionId: sessionId,
        finishedAt: fixtureTime,
      );
      dao.insertRun(run);
      return run;
    }

    void verdict(VerificationVerdict verdict) => dao.insertRunCheck(
      AutomationCheckVerdict(
        runId: 'run1',
        ordinal: 1,
        name: 'tests',
        command: const ['dart', 'test'],
        verdict: verdict,
        reason: verdict == VerificationVerdict.fail ? '2 failed' : 'ok',
        checkedAt: fixtureTime,
      ),
    );

    setUp(() {
      db = fixtureDatabase();
      insertSession(db, 's1', status: 'completed');
      dao = AutomationDao(db);
      resumes = ScheduledResumeDao(db);
      notified = [];
    });
    tearDown(() => db.close());

    test('a failed check tells the agent, with what failed', () {
      arm(
        AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.check),
          AutomationStep(
            kind: AutomationStepKind.tell,
            when: AutomationStepWhen.failure,
            text: 'The checks failed:\n{{steps.check.output}}\nFix them.',
          ),
        ]),
      );
      final run = settled();
      verdict(VerificationVerdict.fail);
      followUps().after(run);

      final resume = resumes.liveFor('s1')!;
      expect(resume.message, contains('tests: Fail. 2 failed'));
      expect(resume.fireAt, fixtureTime);
      expect(resume.scheduledBy, 'automation "Nightly"');
      final step = dao.runById('run1')!.stepResults.single;
      expect(step.kind, AutomationStepKind.tell);
      expect(step.outcome, AutomationStepOutcome.done);
    });

    test('a passing run skips a failure step, and says so', () {
      arm(
        AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.check),
          AutomationStep(
            kind: AutomationStepKind.tell,
            when: AutomationStepWhen.failure,
            text: 'Fix it',
          ),
          AutomationStep(
            kind: AutomationStepKind.notify,
            when: AutomationStepWhen.always,
            text: '{{project}}: {{run.status}}',
          ),
        ]),
      );
      final run = settled();
      verdict(VerificationVerdict.pass);
      followUps().after(run);

      expect(resumes.liveFor('s1'), isNull);
      expect(notified.single, (text: 'repo: succeeded', failed: false));
      final steps = dao.runById('run1')!.stepResults;
      expect(steps.map((s) => s.outcome), [
        AutomationStepOutcome.skipped,
        AutomationStepOutcome.done,
      ]);
    });

    test('an inconclusive check is not a success', () {
      arm(
        AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.check),
          AutomationStep(
            kind: AutomationStepKind.notify,
            when: AutomationStepWhen.failure,
          ),
        ]),
      );
      final run = settled();
      verdict(VerificationVerdict.inconclusive);
      followUps().after(run);
      expect(notified.single.failed, isTrue);
    });

    test('a run that started no session cannot be told, and says why', () {
      arm(
        AutomationSteps(const [
          AutomationStep(
            kind: AutomationStepKind.tell,
            when: AutomationStepWhen.failure,
            text: 'Fix it',
          ),
        ]),
      );
      final run = settled(state: AutomationRunState.failed, sessionId: null);
      followUps().after(run);
      final step = dao.runById('run1')!.stepResults.single;
      expect(step.outcome, AutomationStepOutcome.failed);
      expect(step.detail, 'This run started no session to tell.');
    });

    test('the standard steps record nothing after a run', () {
      arm(AutomationSteps.standard);
      final run = settled();
      followUps().after(run);
      expect(dao.runById('run1')!.stepResults, isEmpty);
      expect(notified, isEmpty);
    });
  });
}
