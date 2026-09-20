import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_service.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_settings.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_turn_hints.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:logging/logging.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

class _MemoryGitFiles implements GitFiles {
  final Map<String, String> written = {};
  @override
  Future<void> createDirectory(String path) async {}
  @override
  Future<bool> exists(String path) async => written.containsKey(path);
  @override
  Future<PathEntry> typeOf(String path) async => throw UnimplementedError();
  @override
  Future<void> writeString(String path, String contents) async =>
      written[path] = contents;
  @override
  Future<String?> readString(String path) async => written[path];
}

/// When a turn becomes a checkpoint: the status pipeline as it really moves.
void main() {
  late AppDatabase db;
  late MovableClock clock;
  late AgentHookReports reports;
  late SessionStatusRegistry registry;
  late ProviderContainer container;
  late List<WatchedSession> watched;
  late int tree;
  String? fixedTree;
  var failAdd = false;

  CommandResult respond(CommandRequest request) {
    final args = request.arguments;
    String? out;
    if (failAdd && args.contains('add')) {
      return const CommandResult(exitCode: 128, stdout: '', stderr: 'boom');
    }
    if (args.contains('--absolute-git-dir') ||
        args.contains('--git-common-dir')) {
      out = 'C:/src/demo/app/.git';
    } else if (args.contains('write-tree')) {
      // A different tree every time: the working tree always moved.
      out = fixedTree ?? 'tree${tree++}';
    } else if (args.contains('commit-tree')) {
      out = 'commit$tree';
    }
    return CommandResult(exitCode: 0, stdout: out ?? '', stderr: '');
  }

  WatchedSession watch(String rowId, String cliId) => WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, cliId),
    label: rowId,
    openId: rowId,
    imported: false,
  );

  setUp(() async {
    db = AppDatabase.memory();
    clock = MovableClock(testTime);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), clock);
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', status: SessionStatus.running));
    tree = 1;
    fixedTree = null;
    failAdd = false;
    var ids = 0;
    reports = AgentHookReports();
    watched = [watch('s1', 'cli-1')];
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(clock),
        agentHookReportsProvider.overrideWithValue(reports),
        sessionStatusRegistryProvider.overrideWithValue(registry),
        checkpointServiceProvider.overrideWithValue(
          CheckpointService(
            runnerFactory: FakeCommandRunnerFactory(
              fallback: FakeCommandRunner(responder: respond),
            ),
            environmentDao: ExecutionEnvironmentDao(db),
            dao: CheckpointDao(db),
            clock: clock,
            newId: () => 'ckpt${++ids}',
            files: _MemoryGitFiles(),
          ),
        ),
      ],
    );
    await registry.cycle();
  });

  tearDown(() {
    registry.dispose();
    container.dispose();
    db.close();
  });

  /// What `LauncherControlServer._startCheckpointRecorder` does.
  void startRecorder() =>
      container.read(sessionCheckpointRecorderProvider.notifier).start();

  Future<void> hook(
    String cliId,
    AgentActivityStatus status,
    String event,
  ) async {
    reports.record(
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: cliId,
        status: status,
        source: AgentStatusSource.hook,
        observedAt: clock.nowUtc(),
        detail: event,
      ),
    );
    registry.hookReported(AgentSessionKey(AgentIds.claudeCode, cliId));
    await pumpEventQueue();
  }

  List<String> reasonsFor(String sessionId) => [
    for (final c in CheckpointDao(db).forSession(sessionId)) c.reason.name,
  ];

  test(
    'a session running at start is checkpointed when its turn ends',
    () async {
      startRecorder();
      await pumpEventQueue();
      await hook('cli-1', AgentActivityStatus.working, 'UserPromptSubmit');
      await hook('cli-1', AgentActivityStatus.idle, 'Stop');
      await pumpEventQueue();
      expect(reasonsFor('s1'), ['turnStart', 'turn']);
    },
  );

  test('a session started after the recorder is checkpointed too', () async {
    startRecorder();
    await pumpEventQueue();
    SessionDao(db).insert(session(id: 's2', status: SessionStatus.running));
    container
        .read(sessionsRevisionProvider.notifier)
        .changed(const SessionChange.created('s2'));
    watched = [...watched, watch('s2', 'cli-2')];
    await registry.cycle();
    await pumpEventQueue();

    await hook('cli-2', AgentActivityStatus.working, 'UserPromptSubmit');
    await hook('cli-2', AgentActivityStatus.idle, 'Stop');
    await pumpEventQueue();
    expect(reasonsFor('s2'), ['turnStart', 'turn']);
  });

  test('a turn that ends in an API error is still a turn', () async {
    startRecorder();
    await pumpEventQueue();
    await hook('cli-1', AgentActivityStatus.working, 'UserPromptSubmit');
    await hook('cli-1', AgentActivityStatus.failed, 'StopFailure');
    await pumpEventQueue();
    expect(reasonsFor('s1'), ['turnStart', 'turn']);
  });

  test(
    'a turn whose working evidence aged out still ends in a checkpoint',
    () async {
      startRecorder();
      await pumpEventQueue();
      await hook('cli-1', AgentActivityStatus.working, 'UserPromptSubmit');
      // A long think with no tool call: the hook goes stale and nothing else
      // can speak for a native session, so the registry says `unknown`.
      clock.advance(const Duration(minutes: 6));
      await registry.cycle();
      await pumpEventQueue();
      await hook('cli-1', AgentActivityStatus.idle, 'Stop');
      await pumpEventQueue();
      expect(reasonsFor('s1'), ['turnStart', 'turn']);
    },
  );

  test('two hooks landing in one event-loop turn still make a turn', () async {
    startRecorder();
    await pumpEventQueue();
    // A short answer: prompt and Stop arrive back to back.
    reports.record(
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-1',
        status: AgentActivityStatus.working,
        source: AgentStatusSource.hook,
        observedAt: clock.nowUtc(),
        detail: 'UserPromptSubmit',
      ),
    );
    registry.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'cli-1'));
    await hook('cli-1', AgentActivityStatus.idle, 'Stop');
    await pumpEventQueue();
    expect(reasonsFor('s1'), ['turnStart', 'turn']);
  });

  test(
    'the hook holds the tool until the before-turn checkpoint is taken',
    () async {
      // What a PreToolUse hook does: publish the status, then hold the agent's
      // Edit on `holdToolForCheckpoint`. The hold used to read a queue the
      // capture had not joined yet — the registry publishes through a stream —
      // so it returned at once, the tool wrote, and the "before" snapshot was
      // taken of a tree that already held the change it exists to undo.
      // The hook route finds the session by the CLI's own id.
      SessionDao(db).updateExternalSessionId('s1', 'cli-1');
      startRecorder();
      await pumpEventQueue();
      reports.record(
        AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 'cli-1',
          status: AgentActivityStatus.working,
          source: AgentStatusSource.hook,
          observedAt: clock.nowUtc(),
          detail: 'UserPromptSubmit',
        ),
      );
      registry.hookReported(
        const AgentSessionKey(AgentIds.claudeCode, 'cli-1'),
      );

      // No pump: the hold is the only thing between the turn starting and the
      // agent's first tool writing to the tree.
      await holdToolForCheckpoint(
        container,
        agentSessionId: 'cli-1',
        event: 'PreToolUse',
      );

      expect(reasonsFor('s1'), ['turnStart']);
    },
  );

  test('a session whose row is not `running` is checkpointed too', () async {
    // A pane restored after a restart can be live and hooked while its row
    // still carries what the liveness reconciler last wrote.
    SessionDao(db).updateStatus('s1', SessionStatus.unknown);
    startRecorder();
    await pumpEventQueue();
    await hook('cli-1', AgentActivityStatus.working, 'UserPromptSubmit');
    await hook('cli-1', AgentActivityStatus.idle, 'Stop');
    await pumpEventQueue();
    expect(reasonsFor('s1'), ['turnStart', 'turn']);
  });

  Future<void> turn(
    String cliId, {
    AgentActivityStatus end = AgentActivityStatus.idle,
  }) async {
    await hook(cliId, AgentActivityStatus.working, 'UserPromptSubmit');
    await hook(cliId, end, 'Stop');
    await pumpEventQueue();
  }

  test('an approval mid-turn does not end the turn', () async {
    startRecorder();
    await hook('cli-1', AgentActivityStatus.working, 'UserPromptSubmit');
    await hook('cli-1', AgentActivityStatus.awaitingApproval, 'Notification');
    await hook('cli-1', AgentActivityStatus.working, 'PostToolUse');
    await hook('cli-1', AgentActivityStatus.idle, 'Stop');
    await pumpEventQueue();
    expect(reasonsFor('s1'), ['turnStart', 'turn']);
  });

  test(
    'an unchanged tree is not recorded again, and says so in the log',
    () async {
      final lines = <String>[];
      final sub = Logger.root.onRecord.listen((r) => lines.add(r.message));
      addTearDown(sub.cancel);
      Logger.root.level = Level.INFO;
      fixedTree = 'same';
      startRecorder();
      await turn('cli-1');
      await turn('cli-1');
      // The first capture of a session has nothing to compare with; after it
      // every capture of the same tree is a skip.
      expect(reasonsFor('s1'), ['turnStart']);
      expect(
        lines.where((l) => l.contains('unchanged since its last checkpoint')),
        hasLength(3),
      );
      expect(
        lines.where((l) => l.startsWith('Checkpoint 1 before')),
        hasLength(1),
      );
    },
  );

  test(
    'a failed capture is logged and the next turn is still recorded',
    () async {
      final lines = <String>[];
      final sub = Logger.root.onRecord.listen((r) => lines.add(r.message));
      addTearDown(sub.cancel);
      Logger.root.level = Level.INFO;
      startRecorder();
      failAdd = true;
      await turn('cli-1');
      expect(reasonsFor('s1'), isEmpty);
      expect(
        lines.where((l) => l.contains('No checkpoint for session s1')),
        hasLength(1),
        reason: 'logged once, not once per edge',
      );
      failAdd = false;
      await turn('cli-1');
      expect(reasonsFor('s1'), ['turnStart', 'turn']);
    },
  );

  test('a session with no repository is skipped with its reason', () async {
    final lines = <String>[];
    final sub = Logger.root.onRecord.listen((r) => lines.add(r.message));
    addTearDown(sub.cancel);
    Logger.root.level = Level.INFO;
    watched = [...watched, watch('gone', 'cli-9')];
    await registry.cycle();
    startRecorder();
    await turn('cli-9');
    expect(
      lines,
      contains(
        'No checkpoint for session gone: it has no repository to '
        'checkpoint.',
      ),
    );
  });

  test('a registry that is replaced is watched again', () async {
    startRecorder();
    // What a rebuilt `sessionStatusRegistryProvider` does to the old one.
    registry.dispose();
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    );
    container.updateOverrides([
      ...fakeTerminalOverrides(database: db),
      clockProvider.overrideWithValue(clock),
      agentHookReportsProvider.overrideWithValue(reports),
      sessionStatusRegistryProvider.overrideWithValue(registry),
      checkpointServiceProvider.overrideWithValue(
        container.read(checkpointServiceProvider),
      ),
    ]);
    await registry.cycle();
    await pumpEventQueue();
    await turn('cli-1');
    expect(reasonsFor('s1'), ['turnStart', 'turn']);
  });

  test('turns are numbered and carry the prompt a hook sent', () async {
    SessionDao(db).updateExternalSessionId('s1', 'cli-1');
    startRecorder();
    recordCheckpointHints(
      container,
      agentId: AgentIds.claudeCode,
      agentSessionId: 'cli-1',
      event: 'UserPromptSubmit',
      body: '{"session_id":"cli-1","prompt":"Fix the login redirect"}',
    );
    await turn('cli-1');
    fixedTree = 'same';
    // A turn that changes nothing writes nothing, and still uses its number.
    await turn('cli-1');
    await turn('cli-1');
    fixedTree = null;
    await turn('cli-1');

    final rows = CheckpointDao(db).forSession('s1');
    expect(
      [for (final c in rows) '${c.reason.name}:${c.turn}'],
      ['turnStart:1', 'turn:1', 'turnStart:2', 'turnStart:4', 'turn:4'],
    );
    expect(rows.first.prompt, 'Fix the login redirect');
    expect(rows[1].prompt, 'Fix the login redirect');
    expect(
      rows.last.prompt,
      isNull,
      reason: 'a turn no hook announced does not inherit an old prompt',
    );
  });

  test('a restart continues the numbering from the store', () async {
    startRecorder();
    await turn('cli-1');
    container.invalidate(sessionCheckpointRecorderProvider);
    startRecorder();
    await turn('cli-1');
    expect(
      [for (final c in CheckpointDao(db).forSession('s1')) c.turn],
      [1, 1, 2, 2],
    );
  });

  test(
    'a session on an SSH host is skipped, and the panel can say why',
    () async {
      ExecutionEnvironmentDao(db).upsert(sshEnvFixture());
      RepositoryDao(
        db,
      ).insert(repository(id: 'r2', environmentId: 'ssh:h1', path: '/srv/app'));
      SessionDao(db).insert(
        session(id: 's3', repositoryId: 'r2', status: SessionStatus.running),
      );
      watched = [...watched, watch('s3', 'cli-3')];
      await registry.cycle();
      startRecorder();
      await turn('cli-3');
      expect(reasonsFor('s3'), isEmpty);
      expect(
        container.read(checkpointSkipReasonsProvider)['s3'],
        'checkpoints are not supported for repositories on build-box: they '
        'need a private git index this machine can write to',
      );
    },
  );

  test(
    'with automatic checkpoints off a turn records nothing, and says so',
    () async {
      container.read(checkpointSettingsProvider.notifier).setAutomatic(false);
      startRecorder();
      await turn('cli-1');
      expect(reasonsFor('s1'), isEmpty);
      expect(
        container.read(checkpointSkipReasonsProvider)['s1'],
        kAutomaticCheckpointsOff,
      );
      // Manual capture is still there.
      await container
          .read(sessionCheckpointRecorderProvider.notifier)
          .captureNow('s1');
      expect(reasonsFor('s1'), ['manual']);
    },
  );

  test('the setting is kept in the store', () {
    container.read(checkpointSettingsProvider.notifier)
      ..setAutomatic(false)
      ..setKeepPerRepository(null);
    container.invalidate(checkpointSettingsProvider);
    final read = container.read(checkpointSettingsProvider);
    expect(read.automatic, isFalse);
    expect(read.keepPerRepository, isNull);
  });

  test('a repository past its limit is pruned to it, in batches', () async {
    const repo = EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\src\demo\app',
    );
    final dao = CheckpointDao(db);
    for (var i = 0; i < 59; i++) {
      dao.insert(
        Checkpoint(
          id: 'old$i',
          sessionId: 's1',
          repository: repo,
          sequence: 0,
          treeSha: 'old-tree$i',
          commitSha: 'old-commit$i',
          parentCommitSha: null,
          headSha: null,
          reason: CheckpointReason.turn,
          createdAt: testTime,
        ),
      );
    }
    container
        .read(checkpointSettingsProvider.notifier)
        .setKeepPerRepository(50);
    startRecorder();
    await turn('cli-1');
    // 61 rows is past 50 and its slack of 10: back to the newest 50.
    final kept = dao.forRepository('s1', repo);
    expect(kept, hasLength(50));
    expect(kept.last.reason, CheckpointReason.turn);
    expect(kept.first.parentCommitSha, isNull, reason: 'the chain restarts');
    await turn('cli-1');
    expect(
      dao.forRepository('s1', repo),
      hasLength(52),
      reason: 'within the slack nothing is re-committed',
    );
  });
}
