import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_providers.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_service.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_targets.dart';
import 'package:karmashala/src/features/checkpoints/application/checkpoint_turn_hints.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/notifications/domain/agent_session_key.dart';
import 'package:karmashala/src/features/notifications/domain/watched_session.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import '../terminal/fake_instance.dart';

/// The owner's layout, in real git: a session started in a workspace folder
/// whose projects are nested clones the workspace's `.gitignore` hides. Every
/// edit lands in a clone, so a checkpoint of the session's own repository is
/// the same tree every turn — the "turn #1 · 0 files" and nothing after it.
/// `checkpointTargetsFor` wants a `Ref`; a throwaway provider lends one.
final checkpointTargetsProbe =
    FutureProvider.family<List<EnvironmentPath>, String>(
      (ref, sessionId) => checkpointTargetsFor(ref, sessionId),
    );

void main() {
  final hasGit = Process.runSync('git', ['--version']).exitCode == 0;

  late Directory tmp;
  late String hub;
  late String app;
  late AppDatabase db;
  late AgentHookReports reports;
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

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_nested_');
    // git names roots by their real path (`/private/var` on macOS).
    hub = tmp.resolveSymbolicLinksSync();
    app = p.join(hub, 'projects', 'app');
    Directory(app).createSync(recursive: true);
    File(p.join(hub, '.gitignore')).writeAsStringSync('projects/**/\n');
    File(p.join(hub, 'README.md')).writeAsStringSync('hub\n');
    git(hub, ['init', '-q']);
    // Restores are compared byte for byte: with a machine-wide
    // `core.autocrlf=true` (Git for Windows' default) `git apply` writes CRLF.
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

    reports = AgentHookReports();
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
            environmentDao: ExecutionEnvironmentDao(db),
            dao: CheckpointDao(db),
            clock: clock,
            newId: () => 'ckpt${++ids}',
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
    removeTempDirectory(tmp);
  });

  Future<void> hook(
    AgentActivityStatus status,
    String event,
    String body,
  ) async {
    // The intake's order: hints first, then the status.
    recordCheckpointHints(
      container,
      agentId: AgentIds.claudeCode,
      agentSessionId: 'cli-1',
      event: event,
      body: body,
    );
    reports.record(
      AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-1',
        status: status,
        source: AgentStatusSource.hook,
        observedAt: testTime,
        detail: event,
      ),
    );
    registry.hookReported(const AgentSessionKey(AgentIds.claudeCode, 'cli-1'));
    // What the hook route does before it answers a PreToolUse.
    await holdToolForCheckpoint(
      container,
      agentSessionId: 'cli-1',
      event: event,
    );
  }

  /// How long the poll below will wait before it decides nothing more is
  /// coming.
  ///
  /// **A hang-guard, not a performance bound**, and the distinction is the
  /// whole reason this constant has a comment. What the test asserts is that
  /// the turn's end *is* checkpointed, not that it is checkpointed quickly:
  /// every capture spawns a real `git` in a real temporary clone, and under a
  /// full-suite run those spawns compete with every other suite's. At 20 s
  /// this was the flakiest test in the repository — green alone in 11 s, red
  /// in the full gate — because it had quietly become a measurement of how
  /// busy the machine was. Nothing here should ever take two minutes; if it
  /// does, the failure that follows is a real one and says so.
  const waitForCapture = Duration(minutes: 2);

  /// How long the poll gave up after, or null while it has not given up.
  /// Read by the expectation, so a give-up is never silent.
  Duration? gaveUpAfter;

  /// Waits until [count] checkpoints of [path] exist, or gives up and lets the
  /// expectation say what is actually there. The recorder is awaited first;
  /// the poll is for a loaded machine, where the git a capture spawns can take
  /// longer than the hook route's own patience.
  Future<void> untilCheckpoints(String path, int count) async {
    final recorder = container.read(sessionCheckpointRecorderProvider.notifier);
    // Per wait, not per file: three tests share this closure, and a give-up
    // reported against the wrong one would be worse than no report.
    gaveUpAfter = null;
    final started = DateTime.now();
    final deadline = started.add(waitForCapture);
    while (CheckpointDao(
          db,
        ).forSession('s1').where((c) => c.repository.path == path).length <
        count) {
      if (DateTime.now().isAfter(deadline)) {
        gaveUpAfter = DateTime.now().difference(started);
        return;
      }
      await recorder.settled('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  List<Checkpoint> ofRepo(String path) => [
    for (final c in CheckpointDao(db).forSession('s1'))
      if (c.repository.path == path) c,
  ];

  test(
    'an edit in a nested, ignored clone is checkpointed before and after',
    () async {
      container.read(sessionCheckpointRecorderProvider.notifier).start();
      final file = p.join(app, 'main.txt');

      await hook(
        AgentActivityStatus.working,
        'UserPromptSubmit',
        '{"session_id":"cli-1","prompt":"Change the app"}',
      );
      // Encoded, not interpolated: a Windows path's backslashes are not JSON.
      await hook(
        AgentActivityStatus.working,
        'PreToolUse',
        jsonEncode({
          'session_id': 'cli-1',
          'tool_name': 'Edit',
          'tool_input': {'file_path': file},
        }),
      );
      // The tool runs only once the hook has answered.
      File(file).writeAsStringSync('one\nTWO\nthree\n');
      await hook(AgentActivityStatus.idle, 'Stop', '{"session_id":"cli-1"}');
      await untilCheckpoints(app, 2);

      final nested = ofRepo(app);
      expect(
        [for (final c in nested) c.reason],
        [CheckpointReason.turnStart, CheckpointReason.turn],
        // Under a loaded run this has come back with the turn's end missing.
        // The recorder's own reason is the difference between "git said the
        // tree was unchanged" and "the end of the turn was never seen", and
        // guessing between those cost an afternoon. The third possibility —
        // that the wait simply ran out — used to look identical to the second,
        // so the poll now says when it gave up.
        reason:
            'skip reason: '
            '${container.read(checkpointSkipReasonsProvider)['s1'] ?? 'none'}'
            '${gaveUpAfter == null ? '' : '; the poll gave up after '
                      '${gaveUpAfter!.inSeconds}s, so this is a wait that ran '
                      'out rather than a capture that was refused'}',
      );
      expect(nested.first.files, isEmpty, reason: 'taken before the edit');
      expect(nested.last.files.map((f) => f.path), ['main.txt']);
      expect(nested.last.additions, 2);
      expect(nested.last.deletions, 1);
      expect(nested.last.turn, 1);
      expect(nested.last.prompt, 'Change the app');

      // Undo the turn: restore its before-turn checkpoint.
      await container.read(checkpointServiceProvider).restore(nested.first);
      expect(File(file).readAsStringSync(), 'one\ntwo\n');
    },
    skip: hasGit ? false : 'git is not on PATH',
  );

  test(
    'a repository outside the session folders is not checkpointed',
    () async {
      final elsewhere = Directory.systemTemp.createTempSync('karmashala_out_');
      addTearDown(() => removeTempDirectory(elsewhere));
      final outside = elsewhere.resolveSymbolicLinksSync();
      File(p.join(outside, 'notes.txt')).writeAsStringSync('x\n');
      git(outside, ['init', '-q']);
      container.read(sessionCheckpointRecorderProvider.notifier).start();

      await hook(
        AgentActivityStatus.working,
        'UserPromptSubmit',
        '{"session_id":"cli-1","prompt":"Read something"}',
      );
      await hook(
        AgentActivityStatus.working,
        'PreToolUse',
        jsonEncode({
          'session_id': 'cli-1',
          'tool_name': 'Read',
          'tool_input': {'file_path': p.join(outside, 'notes.txt')},
        }),
      );
      await hook(AgentActivityStatus.idle, 'Stop', '{"session_id":"cli-1"}');
      await untilCheckpoints(hub, 1);

      expect(ofRepo(outside), isEmpty);
      expect(ofRepo(hub), hasLength(1), reason: 'its own checkout, once');
    },
    skip: hasGit ? false : 'git is not on PATH',
  );

  test(
    'a checkpointed repository whose directory is gone is not tried again',
    () async {
      // A removed git worktree: checkpointed once, then deleted from disk.
      final worktree = p.join(hub, 'projects', 'gone');
      Directory(worktree).createSync(recursive: true);
      File(p.join(worktree, 'a.txt')).writeAsStringSync('a\n');
      git(worktree, ['init', '-q']);
      git(worktree, ['add', '-A']);
      git(worktree, ['commit', '-q', '-m', 'gone']);
      final envId = ExecutionEnvironmentDao(db).getAll().first.id;
      final gone = EnvironmentPath(environmentId: envId, path: worktree);
      File(p.join(worktree, 'a.txt')).writeAsStringSync('b\n');
      expect(
        await container
            .read(checkpointServiceProvider)
            .capture(gone, sessionId: 's1'),
        isNotNull,
      );
      Directory(worktree).deleteSync(recursive: true);

      expect(
        await container.read(checkpointTargetsProbe('s1').future),
        isNot(contains(gone)),
      );

      container.read(sessionCheckpointRecorderProvider.notifier).start();
      await hook(
        AgentActivityStatus.working,
        'UserPromptSubmit',
        '{"session_id":"cli-1","prompt":"Carry on"}',
      );
      await hook(AgentActivityStatus.idle, 'Stop', '{"session_id":"cli-1"}');
      await untilCheckpoints(worktree, 1);

      expect(
        container.read(checkpointSkipReasonsProvider)['s1'] ?? '',
        isNot(contains('failed')),
      );
      // History is kept: forgetting where to look is not deleting what was seen.
      expect(ofRepo(worktree), hasLength(1));
    },
    skip: hasGit ? false : 'git is not on PATH',
  );

  test('pruning leaves a chain git holds, of only the kept trees', () async {
    final service = container.read(checkpointServiceProvider);
    final envId =
        CheckpointDao(db).latestFor('s1')?.repository.environmentId ??
        ExecutionEnvironmentDao(db).getAll().first.id;
    final repo = EnvironmentPath(environmentId: envId, path: app);
    for (var i = 0; i < 3; i++) {
      File(p.join(app, 'main.txt')).writeAsStringSync('v$i\n');
      expect(await service.capture(repo, sessionId: 's1'), isNotNull);
    }
    expect(await service.prune(repo, sessionId: 's1', keep: 1), 2);

    final kept = CheckpointDao(db).forRepository('s1', repo).single;
    final count = Process.runSync('git', [
      '-C',
      app,
      'rev-list',
      '--count',
      Checkpoint.refFor('s1'),
    ]);
    expect((count.stdout as String).trim(), '1');
    final tree = Process.runSync('git', [
      '-C',
      app,
      'rev-parse',
      '${kept.commitSha}^{tree}',
    ]);
    expect((tree.stdout as String).trim(), kept.treeSha);
    // And it still restores.
    File(p.join(app, 'main.txt')).writeAsStringSync('later\n');
    await service.restore(kept, confirm: true);
    expect(File(p.join(app, 'main.txt')).readAsStringSync(), 'v2\n');
  }, skip: hasGit ? false : 'git is not on PATH');
}
