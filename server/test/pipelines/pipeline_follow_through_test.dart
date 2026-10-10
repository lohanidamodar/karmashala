import 'dart:async';

import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/pipelines.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart' show PipelineDao;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/pipelines/pipeline_follow_through.dart';
import 'package:karmashala_host/src/pipelines/server_pipelines.dart';
import 'package:karmashala_notifications/attention.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

import '../mcp/tools/tool_harness.dart';

/// What follows a pipeline run at the server: an automation's step starts one
/// as background work in its name, and a run's gates and failures reach the
/// inbox, opening the run.
void main() {
  late ToolHarness h;
  late List<LaunchPriority> priorities;
  late _Turns turns;
  late ServerPipelines pipelines;
  late List<InboxItem> raised;
  late List<String> retired;
  late List<PipelineRun> moves;

  setUp(() {
    h = ToolHarness();
    priorities = [];
    turns = _Turns();
    raised = [];
    retired = [];
    moves = [];
    var started = 0;
    var ids = 0;
    pipelines = ServerPipelines(
      records: PipelineDao(h.db),
      launcher: ServerStageLauncher(
        defaultInstallation: (_) => 'a1',
        start: (spec, priority) async {
          priorities.add(priority);
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
      tell: (_) {},
      hasRepository: (id) => id == 'r1',
      now: () => h.now,
      newId: () => 'p${++ids}',
    );
    final inbox = PipelineInbox(
      raise: raised.add,
      retire: retired.add,
      projectName: (_) => 'shop',
      now: () => h.now,
    );
    pipelines.onRunChanged = (run) {
      moves.add(run);
      inbox.moved(run);
    };
  });
  tearDown(() => h.dispose());

  final automation = Automation(
    id: 'auto1',
    repositoryId: 'r1',
    name: 'Nightly',
    schedule: const AutomationSchedule.cron('0 2 * * *'),
    agentInstallationId: 'a1',
    prompt: 'Run the tests.',
    permissionMode: null,
    enabled: true,
    armedAt: DateTime.utc(2026, 10, 1),
  );
  final automationRun = AutomationRun(
    id: 'run1',
    automationId: 'auto1',
    scheduledFor: DateTime.utc(2026, 10, 10, 2),
    firedAt: DateTime.utc(2026, 10, 10, 2),
    state: AutomationRunState.finished,
    reason: 'done',
  );

  group('the "Run a pipeline" step', () {
    test(
      'starts the run in the automation\'s name, as background work',
      () async {
        final steps = ServerStepPipelines()..pipelines = pipelines;
        final started = await steps.start(
          automation,
          automationRun,
          pipelineId: 'builtin:implement-test-fix',
          repositoryId: 'r1',
          input: 'Fix the failing tests',
        );
        await pumpEventQueue();
        expect(started.name, 'Implement → Test → Fix loop');
        expect(priorities, [LaunchPriority.background]);
        final run = pipelines.records.run(started.runId)!;
        expect(run.startedBy, PipelineRunStarter.automation);
        expect(run.automation?.runId, 'run1');
        expect(run.automation?.name, 'Nightly');
        expect(run.byPerson, isFalse);
      },
    );

    test('a gone pipeline or checkout is a reason, not a crash', () async {
      final steps = ServerStepPipelines();
      await expectLater(
        steps.start(
          automation,
          automationRun,
          pipelineId: 'builtin:implement-test-fix',
          repositoryId: 'r1',
          input: 'x',
        ),
        throwsA(isA<StateError>()),
      );
      steps.pipelines = pipelines;
      await expectLater(
        steps.start(
          automation,
          automationRun,
          pipelineId: 'nope',
          repositoryId: 'r1',
          input: 'x',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('gone'),
          ),
        ),
      );
      await expectLater(
        steps.start(
          automation,
          automationRun,
          pipelineId: 'builtin:implement-test-fix',
          repositoryId: 'elsewhere',
          input: 'x',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not in the workspace'),
          ),
        ),
      );
    });
  });

  group('the inbox', () {
    test(
      'a gate files an item that opens the run, gone once approved',
      () async {
        final run = pipelines.startRun(
          definition: kPipelineTemplates.first,
          repositoryId: 'r1',
          input: 'Add a badge',
          byPerson: true,
        );
        await pumpEventQueue();
        turns.answer('stage-1', 'The plan');
        await pumpEventQueue();
        final item = raised.single;
        expect(item.kind, InboxItemKind.pipelineWaiting);
        expect(item.session.openId, pipelineInboxOpenId(run.id));
        expect(pipelineRunIdOfInboxId(item.session.openId), run.id);
        expect(item.detail, contains('approval at Plan'));
        expect(item.detail, contains('shop'));

        pipelines.runner.approve(run.id);
        await pumpEventQueue();
        expect(retired, [item.id]);
      },
    );

    test('a failure files an item', () async {
      pipelines.startRun(
        definition: kPipelineTemplates.first,
        repositoryId: 'r1',
        input: 'Add a badge',
      );
      await pumpEventQueue();
      turns.fail('stage-1', 'The agent stopped with an error.');
      await pumpEventQueue();
      final item = raised.single;
      expect(item.kind, InboxItemKind.pipelineFailed);
      expect(item.detail, contains('Failed at Plan'));
    });

    test('a run first seen already held files nothing again', () {
      final inbox = PipelineInbox(
        raise: raised.add,
        retire: retired.add,
        projectName: (_) => 'shop',
        now: () => h.now,
      );
      inbox.moved(
        PipelineRun(
          id: 'old',
          definition: kPipelineTemplates.first,
          repositoryId: 'r1',
          input: 'x',
          state: PipelineRunState.waiting,
          createdAt: h.now,
          updatedAt: h.now,
        ),
      );
      expect(raised, isEmpty);
    });
  });
}

class _Turns implements StageWatcher {
  final _turns = <String, Completer<StageTurn>>{};

  Completer<StageTurn> _of(String id) => _turns[id] ??= Completer();

  void answer(String id, String text) => _of(id).complete(StageTurn.done(text));

  void fail(String id, String why) => _of(id).complete(StageTurn.failed(why));

  @override
  Future<StageTurn> turnOf(String sessionId, {required DateTime since}) =>
      _of(sessionId).future;

  @override
  Future<void> stop(String sessionId) async {}
}
