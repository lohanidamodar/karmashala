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
import 'package:karmashala/src/features/checkpoints/application/checkpoint_turn_hints.dart';
import 'package:karmashala/src/features/checkpoints/application/session_checkpoint_recorder.dart';
import 'package:karmashala/src/features/checkpoints/data/checkpoint_dao.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint.dart';
import 'package:karmashala/src/features/checkpoints/domain/checkpoint_title.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
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

/// **What a loaded machine does to a `PreToolUse` hold, made deterministic.**
///
/// `holdToolForCheckpoint` waits for the queued before-turn snapshot but only
/// for [kCheckpointHookHold], because the installed hook script gives `curl`
/// two seconds. When that bound expires the tool is released and writes, and
/// the queued snapshot then runs against a tree the edit is already in — the
/// one thing an undo-the-turn checkpoint must not be.
///
/// Waiting for a *busy machine* to produce that is not a test; making the
/// capture itself slow is the same thing with the load taken out. [_SlowCapture]
/// puts a fixed delay in front of every `git` call the real service makes, so
/// the real hold, on the real route, with its real bound, expires — every run,
/// on any machine. Nothing else about the sequence is simulated: the hooks,
/// the queue, the status registry and the git repositories are all the real
/// ones.
class _SlowCapture extends CheckpointService {
  _SlowCapture({
    required super.runnerFactory,
    required super.environmentDao,
    required super.dao,
    required super.clock,
    required super.newId,
    required this.delay,
  });

  /// How long a capture takes before it looks at the working tree. The whole
  /// point is that it is **longer than [kCheckpointHookHold]**: the snapshot
  /// is taken after the hold has given up and the tool has written.
  final Duration delay;

  @override
  Future<Checkpoint?> capture(
    EnvironmentPath repo, {
    required String sessionId,
    CheckpointReason reason = CheckpointReason.turn,
    String? label,
    bool evenIfUnchanged = false,
    int? turn,
    String? prompt,
  }) async {
    await Future<void>.delayed(delay);
    return super.capture(
      repo,
      sessionId: sessionId,
      reason: reason,
      label: label,
      evenIfUnchanged: evenIfUnchanged,
      turn: turn,
      prompt: prompt,
    );
  }
}

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

  /// What a checkpoint's *tree* holds at [path] — the snapshot itself, not the
  /// working directory it was taken from.
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
    tmp = Directory.systemTemp.createTempSync('karmashala_hold_');
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
          _SlowCapture(
            runnerFactory: const CommandRunnerFactory(),
            environmentDao: ExecutionEnvironmentDao(db),
            dao: CheckpointDao(db),
            clock: clock,
            newId: () => 'ckpt${++ids}',
            // Comfortably past the 1.5 s hold, so the give-up is a fact of the
            // arithmetic rather than of how busy the machine is.
            delay: const Duration(seconds: 3),
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

  /// One hook, in the intake's order: hints, then the status, then the one
  /// bounded hold the route takes before it answers.
  Future<void> hook(
    AgentActivityStatus status,
    String event,
    String body,
  ) async {
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
    await holdToolForCheckpoint(
      container,
      agentSessionId: 'cli-1',
      event: event,
    );
  }

  List<Checkpoint> ofRepo(String path) => [
    for (final c in CheckpointDao(db).forSession('s1'))
      if (c.repository.path == path) c,
  ];

  /// Waits until [count] checkpoints of [path] exist, or gives up. A hang
  /// guard; see `checkpoint_nested_repository_test.dart` for why it is minutes.
  Future<void> untilCheckpoints(String path, int count) async {
    final recorder = container.read(sessionCheckpointRecorderProvider.notifier);
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (ofRepo(path).length < count) {
      if (DateTime.now().isAfter(deadline)) return;
      await recorder.settled('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'a hold that expires before the snapshot leaves an undo point taken after '
    'the edit, and says so',
    () async {
      container.read(sessionCheckpointRecorderProvider.notifier).start();
      final file = p.join(app, 'main.txt');
      const edited = 'one\nTWO\nthree\n';

      await hook(
        AgentActivityStatus.working,
        'UserPromptSubmit',
        '{"session_id":"cli-1","prompt":"Change the app"}',
      );
      // The turn has begun and its own checkout is checkpointed: everything
      // below is about the *nested* repository the tool is about to name.
      await untilCheckpoints(hub, 1);
      expect(ofRepo(hub), hasLength(1), reason: 'the turn started');
      expect(ofRepo(app), isEmpty, reason: 'nothing has named it yet');

      // The tool names a path in the nested clone. The hold runs for its whole
      // 1.5 s and gives up: the queued snapshot is three seconds of `git` away.
      final heldFor = Stopwatch()..start();
      await hook(
        AgentActivityStatus.working,
        'PreToolUse',
        jsonEncode({
          'session_id': 'cli-1',
          'tool_name': 'Edit',
          'tool_input': {'file_path': file},
        }),
      );
      heldFor.stop();
      expect(
        heldFor.elapsed,
        greaterThanOrEqualTo(kCheckpointHookHold),
        reason: 'the hold expired rather than being satisfied',
      );
      expect(
        ofRepo(app),
        isEmpty,
        reason: 'the tool is released with no before-turn snapshot taken',
      );
      // The tool is released and writes.
      File(file).writeAsStringSync(edited);
      // The hub is edited too, so the turn's end has something to write and
      // this test has a positive signal to wait on rather than an absence.
      File(p.join(hub, 'README.md')).writeAsStringSync('hub\nchanged\n');

      await hook(AgentActivityStatus.idle, 'Stop', '{"session_id":"cli-1"}');
      await untilCheckpoints(hub, 2);
      await container
          .read(sessionCheckpointRecorderProvider.notifier)
          .settled('s1');

      // Link 1: the turn's end was seen and recorded, for the repository whose
      // snapshot was taken in time.
      expect(
        [for (final c in ofRepo(hub)) c.reason],
        [CheckpointReason.turnStart, CheckpointReason.turn],
        reason: 'the turn ended and the hub was checkpointed both sides',
      );

      // Link 2: the nested clone has only a before-turn checkpoint. The turn's
      // end found nothing changed, so there is no "after" to diff against.
      final nested = ofRepo(app);
      expect(
        [for (final c in nested) c.reason],
        [CheckpointReason.turnStart],
        reason: 'only the before-turn snapshot exists',
      );

      // Link 3 — **the defect**. That snapshot is of the edited tree: the undo
      // point for this turn was taken after the edit it exists to undo.
      expect(
        blobIn(app, nested.single.treeSha, 'main.txt'),
        edited,
        reason: 'the before-turn snapshot already contains the edit',
      );

      // Link 4: restoring it is a no-op, so the turn cannot be undone.
      final outcome = await container
          .read(checkpointServiceProvider)
          .restore(nested.single, confirm: true);
      expect(outcome.alreadyThere, isTrue);
      expect(File(file).readAsStringSync(), edited);

      // Link 5 — **what the fix changes**. It used to be silent: the row said
      // "Before turn 1" and nothing anywhere recorded that the claim in those
      // words had not been verified. Now the row carries the caveat, in the
      // database, on the checkpoint the user would restore.
      expect(nested.single.label, lateTurnStartLabel(1));
      expect(
        checkpointTitle(nested.single),
        'Before: Change the app — may already include its first edit',
        reason: 'the panel says so where the Restore button is',
      );
      // And the repository whose snapshot *was* taken in time is not marked:
      // one expired hold does not cast doubt on a row written before it.
      expect(ofRepo(hub).first.label, isNull);
      expect(checkpointTitle(ofRepo(hub).first), 'Before: Change the app');
    },
    skip: hasGit ? false : 'git is not on PATH',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
