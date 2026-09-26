import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_intake.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint_title.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import '../terminal/fake_instance.dart';

/// **The spool transport cannot hold a tool, so it must not claim it did.**
///
/// A WSL agent's hook script writes its payload into a spool directory and
/// exits; the tool runs straight after, and the app reads the payload on its
/// next poll. Every hook here goes through the real
/// `agentHookSpoolDrainerProvider` wiring, and the file is edited the instant
/// the `PreToolUse` has been handed over — which is the most time a real agent
/// ever gives: none.
void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String hub;
  late String app;
  late AppDatabase db;
  late SessionStatusRegistry registry;
  late ProviderContainer container;

  void git(String dir, List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      dir,
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ]);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
  }

  String blobIn(String repo, String tree, String path) {
    final result = Process.runSync('git', [
      '-C',
      repo,
      'cat-file',
      '-p',
      '$tree:$path',
    ]);
    if (result.exitCode != 0) fail('git cat-file: ${result.stderr}');
    return result.stdout as String;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_spool_');
    hub = tmp.resolveSymbolicLinksSync();
    app = p.join(hub, 'projects', 'app');
    Directory(app).createSync(recursive: true);
    File(p.join(hub, '.gitignore')).writeAsStringSync('projects/**/\n');
    File(p.join(hub, 'README.md')).writeAsStringSync('hub\n');
    git(hub, ['init', '-q']);
    git(hub, ['config', 'core.autocrlf', 'false']);
    git(hub, ['add', '-A']);
    git(hub, ['commit', '-q', '-m', 'hub']);
    File(p.join(app, 'main.txt')).writeAsStringSync('one\ntwo\n');
    git(app, ['init', '-q']);
    git(app, ['config', 'core.autocrlf', 'false']);
    git(app, ['add', '-A']);
    git(app, ['commit', '-q', '-m', 'app']);

    db = AppDatabase.memory();
    final clock = FixedClock(testTime);
    final envId = ensureLocalEnvironment(ExecutionEnvironmentDao(db), clock);
    ProjectDao(db).insert(project(environmentId: envId, path: hub));
    RepositoryDao(db).insert(repository(environmentId: envId, path: hub));
    AgentInstallationDao(db).insert(agentInstallation(environmentId: envId));
    SessionDao(db)
      ..insert(
        session(
          status: SessionStatus.running,
          workingDirectory: EnvironmentPath(environmentId: envId, path: hub),
        ),
      )
      ..updateExternalSessionId('s1', 'cli-1');

    final reports = AgentHookReports();
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => const [
        WatchedSession(
          key: AgentSessionKey(AgentIds.claudeCode, 'cli-1'),
          label: 's1',
          openId: 's1',
          imported: false,
        ),
      ],
      clock: clock,
    );
    var ids = 0;
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(clock),
        agentHookReportsProvider.overrideWithValue(reports),
        sessionStatusRegistryProvider.overrideWithValue(registry),
        checkpointServiceProvider.overrideWithValue(
          CheckpointService(
            runnerFactory: const CommandRunnerFactory(),
            environmentOf: ExecutionEnvironmentDao(db).getById,
            dao: CheckpointDao(db),
            clock: clock,
            newId: () => 'ckpt${++ids}',
          ),
        ),
      ],
    );
    await registry.cycle();
    container.read(sessionCheckpointRecorderProvider.notifier).start();
  });

  tearDown(() {
    registry.dispose();
    container.dispose();
    db.close();
    removeTempDirectory(tmp);
  });

  /// One payload as the drainer hands it over. Synchronous, like the real
  /// thing: there is nothing to await, because there is no one to answer.
  void spooled(String event, Map<String, Object?> body) => container
      .read(agentHookSpoolDrainerProvider)
      .onEvent(
        AgentHookSpoolEvent(
          agentId: AgentIds.claudeCode,
          event: event,
          body: jsonEncode({'session_id': 'cli-1', ...body}),
          firedAt: testTime,
        ),
      );

  List<Checkpoint> ofRepo(String path) => [
    for (final c in CheckpointDao(db).forSession('s1'))
      if (c.repository.path == path) c,
  ];

  Future<void> untilCheckpoints(String path, int count) async {
    final recorder = container.read(sessionCheckpointRecorderProvider.notifier);
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (ofRepo(path).length < count) {
      if (DateTime.now().isAfter(deadline)) return;
      await recorder.settled('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> settle() =>
      container.read(sessionCheckpointRecorderProvider.notifier).settled('s1');

  Map<String, Object?> edit(String file) => {
    'tool_name': 'Edit',
    'tool_input': {'file_path': file},
  };

  test(
    'a repository first named by a spooled tool is snapshotted after its edit, '
    'every time, and the row says so',
    () async {
      final file = p.join(app, 'main.txt');
      const edited = 'one\nTWO\nthree\n';

      spooled('UserPromptSubmit', {'prompt': 'Change the app'});
      await untilCheckpoints(hub, 1);
      await settle();
      expect(ofRepo(app), isEmpty, reason: 'nothing has named it yet');

      spooled('PreToolUse', edit(file));
      // The hook script has already exited: the tool runs now.
      File(file).writeAsStringSync(edited);
      File(p.join(hub, 'README.md')).writeAsStringSync('hub\nchanged\n');

      spooled('Stop', const {});
      await untilCheckpoints(hub, 2);
      await settle();

      final nested = ofRepo(app);
      expect([for (final c in nested) c.reason], [CheckpointReason.turnStart]);
      // The gap: no hold, so the "before" is after — not by a race, by order.
      expect(blobIn(app, nested.single.treeSha, 'main.txt'), edited);
      // The fix: it says so.
      expect(nested.single.label, lateTurnStartLabel(1));
      expect(
        checkpointTitle(nested.single),
        'Before: Change the app — may already include its first edit',
      );

      // The turn-start snapshot returned before any tool was announced: it is
      // genuinely before, and is not smeared with the warning.
      final before = ofRepo(hub).first;
      expect(before.reason, CheckpointReason.turnStart);
      expect(before.label, isNull);
      expect(blobIn(hub, before.treeSha, 'README.md'), 'hub\n');
    },
    skip: hasGit ? false : 'git is not on PATH',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a turn-start snapshot still running when a spooled tool is read is marked, '
    'and the next turn does not inherit the mark',
    () async {
      // One drain tick carrying both: the tool was announced while the
      // turn-start capture had not yet returned.
      spooled('UserPromptSubmit', {'prompt': 'Run the build'});
      spooled('PreToolUse', {
        'tool_name': 'Bash',
        'tool_input': {'command': 'make'},
      });
      await untilCheckpoints(hub, 1);
      await settle();
      File(p.join(hub, 'README.md')).writeAsStringSync('hub\nbuilt\n');
      spooled('Stop', const {});
      await untilCheckpoints(hub, 2);
      await settle();
      expect(ofRepo(hub).first.reason, CheckpointReason.turnStart);
      expect(ofRepo(hub).first.label, lateTurnStartLabel(1));

      // Between turns the user edits, so turn 2 has a before-turn to write.
      File(p.join(hub, 'README.md')).writeAsStringSync('hub\nby hand\n');
      spooled('UserPromptSubmit', {'prompt': 'Again'});
      await untilCheckpoints(hub, 3);
      await settle();
      final second = ofRepo(hub)[2];
      expect(second.reason, CheckpointReason.turnStart);
      expect(second.turn, 2);
      expect(second.label, isNull, reason: 'the mark belongs to turn 1');
    },
    skip: hasGit ? false : 'git is not on PATH',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'the HTTP route, when its hold is met, marks nothing: the warning is the '
    "spool's, not every mid-turn snapshot's",
    () async {
      final file = p.join(app, 'main.txt');
      Future<void> posted(String event, Map<String, Object?> body) async {
        final report = applyAgentHookCallback(
          container,
          agentId: AgentIds.claudeCode,
          event: event,
          body: jsonEncode({'session_id': 'cli-1', ...body}),
          observedAt: testTime,
        );
        // The route's hold, without its bound: this test is about who marks,
        // not about a hold that can expire under a loaded gate.
        if (report.sessionId.isNotEmpty) await settle();
      }

      await posted('UserPromptSubmit', {'prompt': 'Change the app'});
      await untilCheckpoints(hub, 1);
      await posted('PreToolUse', edit(file));
      await untilCheckpoints(app, 1);
      File(file).writeAsStringSync('one\nTWO\n');
      await posted('Stop', const {});
      await untilCheckpoints(app, 2);
      await settle();

      final nested = ofRepo(app);
      expect(blobIn(app, nested.first.treeSha, 'main.txt'), 'one\ntwo\n');
      expect(nested.first.label, isNull);
    },
    skip: hasGit ? false : 'git is not on PATH',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
