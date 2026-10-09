import 'dart:async';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/check_runner.dart' show SessionChecks;
import 'package:karmashala_automations/checks.dart' show ProjectCheck;
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/store.dart' show PipelineDao;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/pipelines/pipeline_tool_set.dart';
import 'package:karmashala_host/src/pipelines/server_pipelines.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

/// Pipelines at the server: each stage through the launch path and its gate,
/// the MCP tools an agent drives a run with, and the requests a client sends.
void main() {
  late ToolHarness h;
  late List<LaunchPriority> priorities;
  late List<SessionStartSpec> specs;
  late _Turns turns;
  late List<DataChange> told;
  late ServerPipelines pipelines;
  late PipelineToolSet tools;

  setUp(() {
    h = ToolHarness();
    priorities = [];
    specs = [];
    turns = _Turns();
    told = [];
    var started = 0;
    pipelines = ServerPipelines(
      records: PipelineDao(h.db),
      launcher: ServerStageLauncher(
        defaultInstallation: (_) => 'a1',
        start: (spec, priority) async {
          priorities.add(priority);
          specs.add(spec);
          final id = 'stage-${++started}';
          return SessionStarted(
            session: Session(
              id: id,
              repositoryId: spec.repositoryId,
              agentInstallationId: spec.installationId,
              title: spec.title,
              useWorktree: spec.worktree,
              status: SessionStatus.running,
              createdAt: h.now,
              parentSessionId: spec.parentSessionId,
              worktree: spec.worktree
                  ? EnvironmentPath(environmentId: 'here', path: '/wt/$id')
                  : spec.existingWorktree,
            ),
          );
        },
      ),
      watcher: turns,
      evidence: ServerStageEvidence(
        listArtifacts: (_) => const [],
        contentOf: (_) async => const [],
        runChecks: (_, {only}) async => null,
        now: () => h.now,
      ),
      tell: told.addAll,
      hasRepository: (id) => id == 'r1',
      now: () => h.now,
      newId: () => 'run-${specs.length}-${told.length}',
    );
    tools = PipelineToolSet(h.context, pipelines: () => pipelines);
  });
  tearDown(() => h.dispose());

  test('templates list the three built-ins and the fields', () async {
    final answer = await h.map(tools, 'pipeline_templates');
    final names = [
      for (final p in answer['pipelines']! as List) (p as Map)['name'],
    ];
    expect(names, [for (final t in kPipelineTemplates) t.name]);
    expect((answer['fields']! as Map).keys, contains('{{loop.feedback}}'));
  });

  test(
    "an agent's run starts its stages as sub-sessions behind the launch limits, "
    'and only it may approve them',
    () async {
      final run = await h.map(tools, 'pipeline_run', {
        'input': 'Add a cart badge',
      }, 's1');
      final runId = run['runId']! as String;
      await pumpEventQueue();
      expect(priorities, [LaunchPriority.background]);
      final plan = specs.single;
      expect(plan.repositoryId, 'r1', reason: "the caller's own checkout");
      expect(plan.parentSessionId, 's1');
      expect(plan.worktree, isFalse);
      expect(plan.titleTyped, isTrue);
      expect(plan.title, 'Plan · Plan → Implement → Review');
      expect(plan.systemPrompt, contains('read-only'));
      expect(plan.prompt, contains('Add a cart badge'));

      turns.answer('stage-1', 'The plan');
      await pumpEventQueue();
      final waiting = await h.map(tools, 'pipeline_status', {'runId': runId});
      expect(waiting['state'], 'waiting');
      expect(waiting['handoff'], 'The plan');

      await expectLater(
        h.call(tools, 'pipeline_approve', {'runId': runId}, 's2'),
        throwsA(isA<StateError>()),
      );
      await h.call(tools, 'pipeline_approve', {
        'runId': runId,
        'handoff': 'The plan, trimmed',
      }, 's1');
      await pumpEventQueue();
      expect(specs, hasLength(2));
      expect(specs[1].worktree, isTrue);
      expect(specs[1].prompt, contains('The plan, trimmed'));
      expect(priorities, [
        LaunchPriority.background,
        LaunchPriority.background,
      ]);

      turns.answer('stage-2', 'Done');
      await pumpEventQueue();
      expect(specs[2].existingWorktree?.path, '/wt/stage-2');
      expect(told.whereType<PipelineRunChanged>(), isNotEmpty);

      final status = await h.map(tools, 'pipeline_status', {'runId': runId});
      final stages = status['stages']! as List;
      expect((stages[1] as Map)['branch'], sessionBranchName('stage-2'));
      expect((stages[0] as Map)['handoff'], 'The plan, trimmed');
    },
  );

  test("a person's run goes ahead of background work, and no agent may "
      'approve it', () async {
    final run =
        await pipelines.handle(
              PipelineRunStart(
                definition: kPipelineTemplates.first,
                repositoryId: 'r1',
                input: 'x',
              ),
            )
            as PipelineRun;
    await pumpEventQueue();
    expect(priorities, [LaunchPriority.interactive]);
    expect(specs.single.parentSessionId, isNull);
    turns.answer('stage-1', 'plan');
    await pumpEventQueue();
    await expectLater(
      h.call(tools, 'pipeline_approve', {'runId': run.id}, 's1'),
      throwsA(isA<StateError>()),
    );
    final approved =
        await pipelines.handle(PipelineRunApprove(run.id)) as PipelineRun;
    expect(approved.state, PipelineRunState.running);
  });

  test('a built-in template is not saved over, and a copy is', () async {
    await expectLater(
      pipelines.handle(PipelineSave(kPipelineTemplates.first)),
      throwsA(isA<DataRefused>()),
    );
    final saved =
        await pipelines.handle(
              PipelineSave(
                kPipelineTemplates.first.copyWith(
                  id: '',
                  name: 'My review',
                  builtIn: false,
                ),
              ),
            )
            as PipelineDefinition;
    expect(saved.id, isNotEmpty);
    expect(told.whereType<PipelineChanged>().single.pipeline.name, 'My review');
    final listed =
        await pipelines.handle(const PipelinesList()) as PipelinesSnapshot;
    expect(listed.saved.single.name, 'My review');
    expect(pipelines.definitionNamed('my review')?.id, saved.id);
  });

  test('a run on a checkout that is not there is refused', () async {
    await expectLater(
      pipelines.handle(
        PipelineRunStart(
          definition: kPipelineTemplates.first,
          repositoryId: 'gone',
          input: 'x',
        ),
      ),
      throwsA(isA<DataRefused>()),
    );
  });

  test(
    'a stage that waited for a slot is found where it works once it ran',
    () async {
      final evidence = ServerStageEvidence(
        listArtifacts: (_) => const [],
        contentOf: (_) async => const [],
        runChecks: (_, {only}) async => null,
        now: () => h.now,
        worktreeOf: (id) => id == 'queued'
            ? const EnvironmentPath(environmentId: 'here', path: '/wt/queued')
            : null,
      );
      final place = await evidence.placeOf('queued');
      expect(place!.worktreePath, '/wt/queued');
      expect(place.branch, sessionBranchName('queued'));
      expect(await evidence.placeOf('unknown'), isNull);
    },
  );

  group('a check gate', () {
    test(
      'runs the named command as one recorded check, with its identity',
      () async {
        List<ProjectCheck>? asked;
        final evidence = ServerStageEvidence(
          listArtifacts: (_) => const [],
          contentOf: (_) async => const [],
          now: () => h.now,
          runChecks: (sessionId, {only}) async {
            asked = only;
            return _ran(VerificationVerdict.fail, exitCode: 1);
          },
        );
        final check = await evidence.check(
          sessionId: 's1',
          repositoryId: 'r1',
          command: 'dart test --reporter expanded',
        );
        expect(asked!.single.command, [
          'dart',
          'test',
          '--reporter',
          'expanded',
        ]);
        expect(check.verdict, VerificationVerdict.fail);
        expect(check.verificationRunId, 'v1');
        expect(check.identity!.head, 'abc1234567');
        expect(check.summary, contains('exit 1'));
        expect(check.summary, contains('2 failed'));
      },
    );

    test('with nothing to run is inconclusive, never a pass', () async {
      final evidence = ServerStageEvidence(
        listArtifacts: (_) => const [],
        contentOf: (_) async => const [],
        now: () => h.now,
        runChecks: (_, {only}) async => null,
      );
      final check = await evidence.check(
        sessionId: 's1',
        repositoryId: 'r1',
        command: '',
      );
      expect(check.verdict, VerificationVerdict.inconclusive);
      expect(check.passed, isFalse);
    });
  });
}

SessionChecks _ran(VerificationVerdict verdict, {required int exitCode}) => (
  checks: [
    CommandCheck(
      name: 'Pipeline check',
      command: const ['dart', 'test'],
      exitCode: exitCode,
      output: '2 failed',
    ),
  ],
  run: VerificationRun(
    id: 'v1',
    title: 'Project checks',
    target: const VerificationTarget.change(),
    startedAt: DateTime.utc(2026, 10, 9),
    artifactDirectory: '/tmp',
    verdict: verdict,
    identity: const CodeIdentity(
      environmentId: 'here',
      path: '/wt',
      head: 'abc1234567',
      tree: 't',
    ),
  ),
);

class _Turns implements StageWatcher {
  final _turns = <String, Completer<StageTurn>>{};

  Completer<StageTurn> _of(String id) => _turns[id] ??= Completer();

  void answer(String id, String text) => _of(id).complete(StageTurn.done(text));

  @override
  Future<StageTurn> turnOf(String sessionId, {required DateTime since}) =>
      _of(sessionId).future;

  @override
  Future<void> stop(String sessionId) async {}
}
