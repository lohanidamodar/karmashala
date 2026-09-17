import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_service.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
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
}
