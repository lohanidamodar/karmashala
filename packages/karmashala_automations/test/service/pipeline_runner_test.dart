import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_core/verdicts.dart';
import 'package:test/test.dart';

import 'pipeline_fakes.dart';

/// A pipeline run against fake agents: hand-offs flow, gates hold, loops are
/// capped, and a restarted runner carries on where the run was.
void main() {
  late MemoryPipelineRecords records;
  late FakeStageLauncher launcher;
  late FakeStageWatcher watcher;
  late FakeStageEvidence evidence;
  late PipelineRunner runner;
  var ids = 0;

  PipelineRunner newRunner() => PipelineRunner(
    records: records,
    launcher: launcher,
    watcher: watcher,
    evidence: evidence,
    now: () => DateTime.utc(2026, 10, 9, 12),
    newId: () => 'run${++ids}',
  );

  setUp(() {
    records = MemoryPipelineRecords();
    launcher = FakeStageLauncher();
    watcher = FakeStageWatcher();
    evidence = FakeStageEvidence();
    runner = newRunner();
  });

  PipelineRun run(String id) => records.run(id)!;

  final threeStages = kPipelineTemplates.first;

  test(
    'a 3-stage run hands each stage on, holding at its approval gate',
    () async {
      final started = runner.start(
        definition: threeStages,
        repositoryId: 'repo',
        input: 'Add a cart badge',
        byPerson: true,
      );
      await pumpEventQueue();
      expect(launcher.launches, hasLength(1));
      final plan = launcher.launches.single;
      expect(plan.workspace, PipelineWorkspace.source);
      expect(plan.priority, StagePriority.person);
      expect(plan.prompt, contains('Task: Add a cart badge'));
      expect(plan.systemPrompt, contains('read-only'));

      evidence.artifacts['s1'] = const [
        PipelineArtifactRef(id: 'a1', title: 'spec.md', path: '/tmp/spec.md'),
      ];
      evidence.texts['a1'] = '1. badge\n2. test';
      watcher.answer('s1', 'Plan: badge then test');
      await pumpEventQueue();

      var now = run(started.id);
      expect(now.state, PipelineRunState.waiting);
      expect(now.current!.state, PipelineStageState.approval);
      expect(now.current!.artifacts.single.title, 'spec.md');
      expect(launcher.launches, hasLength(1), reason: 'held at the gate');

      runner.approve(started.id, handoff: 'Plan: badge only');
      await pumpEventQueue();
      final implement = launcher.launches[1];
      expect(implement.workspace, PipelineWorkspace.newWorktree);
      expect(implement.prompt, contains('## spec.md (from Plan)'));
      expect(implement.prompt, contains('1. badge'));
      expect(implement.prompt, contains('## Hand-off from Plan'));
      expect(
        implement.prompt,
        contains('Plan: badge only'),
        reason: 'the edited hand-off, not the answer',
      );
      expect(implement.prompt, isNot(contains('{{loop.feedback}}')));

      watcher.answer('s2', 'Added the badge');
      await pumpEventQueue();
      final review = launcher.launches[2];
      expect(review.workspace, PipelineWorkspace.previousWorktree);
      expect(review.worktreePath, '/wt/s2');
      expect(review.prompt, contains('branch branch-s2'));
      expect(review.prompt, contains('Added the badge'));

      watcher.answer('s3', 'Fine.\nVERDICT: PASS');
      await pumpEventQueue();
      now = run(started.id);
      expect(now.state, PipelineRunState.finished);
      expect(
        now.records.map((r) => r.state),
        everyElement(PipelineStageState.done),
      );
      expect(now.records.map((r) => r.sessionId), ['s1', 's2', 's3']);
      expect(now.records[1].worktreePath, '/wt/s2');
      expect(now.records[0].handoff, 'Plan: badge only');
    },
  );

  test('a failing check gate stops the run when nothing loops back', () async {
    const definition = PipelineDefinition(
      id: 'p',
      name: 'Build',
      stages: [
        PipelineStage(
          role: 'Build',
          instruction: '{{input}}',
          workspace: PipelineWorkspace.newWorktree,
          gate: PipelineGateKind.check,
          checkCommand: 'dart test',
        ),
        PipelineStage(role: 'Ship', instruction: 'ship'),
      ],
    );
    evidence.verdicts.add(VerificationVerdict.fail);
    final started = runner.start(
      definition: definition,
      repositoryId: 'repo',
      input: 'go',
    );
    await pumpEventQueue();
    expect(launcher.launches.single.priority, StagePriority.background);
    watcher.answer('s1', 'built');
    await pumpEventQueue();
    final now = run(started.id);
    expect(evidence.checks, ['s1@/wt/s1:dart test']);
    expect(now.state, PipelineRunState.failed);
    expect(now.current!.state, PipelineStageState.failed);
    expect(now.current!.check!.verdict, VerificationVerdict.fail);
    expect(now.current!.check!.verificationRunId, 'v1');
    expect(now.reason, contains('2 tests failed'));
    expect(launcher.launches, hasLength(1), reason: 'Ship never started');
  });

  test('a failed review loops back to implement, at most its cap', () async {
    final started = runner.start(
      definition: threeStages.copyWith(
        stages: [
          threeStages.stages[0].copyWith(gate: PipelineGateKind.auto),
          ...threeStages.stages.skip(1),
        ],
      ),
      repositoryId: 'repo',
      input: 'x',
    );
    await pumpEventQueue();
    watcher.answer('s1', 'plan');
    await pumpEventQueue();
    watcher.answer('s2', 'did it');
    await pumpEventQueue();
    watcher.answer('s3', 'Missing tests.\nVERDICT: FAIL');
    await pumpEventQueue();
    expect(launcher.launches, hasLength(4));
    final again = launcher.launches[3];
    expect(again.workspace, PipelineWorkspace.newWorktree);
    expect(again.prompt, contains('## Sent back by Review'));
    expect(again.prompt, contains('Missing tests.'));

    watcher.answer('s4', 'added tests');
    await pumpEventQueue();
    watcher.answer('s5', 'Still no.\nVERDICT: FAIL');
    await pumpEventQueue();
    watcher.answer('s6', 'more');
    await pumpEventQueue();
    watcher.answer('s7', 'Nope.\nVERDICT: FAIL');
    await pumpEventQueue();

    final now = run(started.id);
    expect(now.state, PipelineRunState.failed);
    expect(now.reason, contains('after 2 loop-backs'));
    expect(now.loopsFrom(2), 2);
    expect(launcher.launches, hasLength(7));
  });

  test('a restarted runner carries on at the stage it was at', () async {
    final started = runner.start(
      definition: threeStages,
      repositoryId: 'repo',
      input: 'x',
    );
    await pumpEventQueue();
    // The server stops while Plan runs; its session survives.
    final restarted = newRunner()..resume();
    await pumpEventQueue();
    watcher.answer('s1', 'plan');
    await pumpEventQueue();
    expect(run(started.id).state, PipelineRunState.waiting);
    newRunner()
      ..resume()
      ..approve(started.id);
    await pumpEventQueue();
    expect(launcher.launches.map((l) => l.workspace), [
      PipelineWorkspace.source,
      PipelineWorkspace.newWorktree,
    ]);
    expect(restarted, isNotNull);
  });

  test(
    'a run killed between recording and launching starts that stage again',
    () async {
      final now = DateTime.utc(2026, 10, 9);
      records.putRun(
        PipelineRun(
          id: 'r',
          definition: threeStages,
          repositoryId: 'repo',
          input: 'x',
          state: PipelineRunState.running,
          createdAt: now,
          updatedAt: now,
          records: const [
            PipelineStageRecord(
              stageIndex: 0,
              role: 'Plan',
              attempt: 1,
              state: PipelineStageState.starting,
            ),
          ],
        ),
      );
      runner.resume();
      await pumpEventQueue();
      expect(launcher.launches, hasLength(1));
      expect(run('r').records, hasLength(1));
      expect(run('r').current!.sessionId, 's1');
    },
  );

  test('stop ends the stage, retry starts it again, skip goes on', () async {
    final started = runner.start(
      definition: threeStages,
      repositoryId: 'repo',
      input: 'x',
      startedBySessionId: 'parent',
    );
    await pumpEventQueue();
    await runner.stop(started.id);
    await pumpEventQueue();
    var now = run(started.id);
    expect(now.state, PipelineRunState.stopped);
    expect(now.current!.state, PipelineStageState.stopped);
    expect(watcher.stopped, ['s1']);

    runner.retry(started.id);
    await pumpEventQueue();
    now = run(started.id);
    expect(now.state, PipelineRunState.running);
    expect(now.current!.attempt, 2);
    expect(now.current!.sessionId, 's2');

    watcher.fail('s2', 'The agent exited.');
    await pumpEventQueue();
    expect(run(started.id).state, PipelineRunState.failed);

    runner.skip(started.id);
    await pumpEventQueue();
    now = run(started.id);
    expect(now.records[1].state, PipelineStageState.skipped);
    expect(now.current!.role, 'Implement');
    expect(now.state, PipelineRunState.running);
  });

  test('only the session that started a run may approve it', () async {
    final started = runner.start(
      definition: threeStages,
      repositoryId: 'repo',
      input: 'x',
      startedBySessionId: 'parent',
    );
    await pumpEventQueue();
    watcher.answer('s1', 'plan');
    await pumpEventQueue();
    expect(
      () => runner.approve(started.id, bySessionId: 'stranger'),
      throwsStateError,
    );
    runner.approve(started.id, bySessionId: 'parent');
    await pumpEventQueue();
    expect(launcher.launches.last.parentSessionId, 'parent');
    expect(launcher.launches, hasLength(2));
  });

  test('a launch that fails fails the stage, with why', () async {
    launcher.failRole = 'Plan';
    final started = runner.start(
      definition: threeStages,
      repositoryId: 'repo',
      input: 'x',
    );
    await pumpEventQueue();
    final now = run(started.id);
    expect(now.state, PipelineRunState.failed);
    expect(now.reason, contains('no agent'));
  });

  test('a definition that cannot run is refused before anything starts', () {
    expect(
      () => runner.start(
        definition: const PipelineDefinition(id: 'p', name: 'P', stages: []),
        repositoryId: 'repo',
        input: 'x',
      ),
      throwsArgumentError,
    );
    expect(records.stored, isEmpty);
  });
}
