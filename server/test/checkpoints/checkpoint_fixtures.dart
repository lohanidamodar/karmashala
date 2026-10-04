import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_checkpoints/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final bool hasGit = Process.runSync('git', ['--version']).exitCode == 0;

/// Runs git as the tests' own author, never a signing key.
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

/// The content of [path] in [tree] of the repository at [repo].
String blobIn(String repo, String tree, String path) =>
    Process.runSync('git', ['-C', repo, 'cat-file', '-p', '$tree:$path']).stdout
        as String;

/// Local git, with every call that looks at the working tree held back by
/// [delay] while [slow] is true — a loaded machine, made deterministic — and
/// failing `git add` while [failAdd] is.
class SlowRunners extends CommandRunnerFactory {
  SlowRunners();

  var slow = false;
  var failAdd = false;
  var slowRecord = false;
  Duration delay = const Duration(milliseconds: 600);

  @override
  CommandRunner forEnvironment(ExecutionEnvironment environment) =>
      _SlowRunner(this, super.forEnvironment(environment));
}

class _SlowRunner implements CommandRunner {
  _SlowRunner(this._owner, this._inner);

  final SlowRunners _owner;
  final CommandRunner _inner;

  @override
  String get environmentId => _inner.environmentId;

  @override
  Future<CommandResult> run(CommandRequest request) async {
    if (_owner.failAdd && request.arguments.contains('add')) {
      return const CommandResult(exitCode: 128, stdout: '', stderr: 'boom');
    }
    // `add` is where a capture reads the working tree (into its private
    // index): held back here, the snapshot is of the tree as it is after.
    if (_owner.slow && request.arguments.contains('add')) {
      await Future<void>.delayed(_owner.delay);
    }
    // `commit-tree` is where a snapshot becomes a recorded checkpoint.
    if (_owner.slowRecord && request.arguments.contains('commit-tree')) {
      await Future<void>.delayed(_owner.delay);
    }
    return _inner.run(request);
  }

  @override
  Future<ProcessHandle> start(CommandRequest request) => _inner.start(request);
}

/// One machine for the recorder: a store with this machine's environment
/// (`local`) and an SSH one (`box`), a workspace folder [hub] that is a git
/// repository with a nested, ignored clone [app] under `projects/`, a
/// session `s1` in [hub] whose conversation is `cli-1`, a real data service
/// with a subscribed client that collects what it is told, and the server's
/// [DaemonCheckpoints] over all of it.
class CheckpointWorld {
  CheckpointWorld._();

  late final Directory tmp;
  late final String hub;
  late final String app;
  late final AppDatabase db;
  late final DataService data;
  late final DataSession client;
  late final DaemonCheckpoints checkpoints;
  final runners = SlowRunners();
  final told = <DataChange>[];
  final statuses = StreamController<HostedAgentStatus>.broadcast(sync: true);

  /// Rows the server holds (runs in a PTY of its own).
  final held = <String>{};
  final log = <String>[];
  final at = DateTime.utc(2026, 9, 27, 9);
  var _ids = 0;

  static Future<CheckpointWorld> create({
    Duration hold = kCheckpointHookHold,
    bool holdS1 = false,
  }) async {
    final w = CheckpointWorld._();
    w.tmp = Directory.systemTemp.createTempSync('karmashala_ckpt_');
    // git names roots by their real path (`/private/var` on macOS).
    w.hub = w.tmp.resolveSymbolicLinksSync();
    w.app = p.join(w.hub, 'projects', 'app');
    Directory(w.app).createSync(recursive: true);
    File(p.join(w.hub, '.gitignore')).writeAsStringSync('projects/**/\n');
    File(p.join(w.hub, 'README.md')).writeAsStringSync('hub\n');
    git(w.hub, ['init', '-q']);
    git(w.hub, ['config', 'core.autocrlf', 'false']);
    git(w.hub, ['add', '-A']);
    git(w.hub, ['commit', '-q', '-m', 'hub']);
    File(p.join(w.app, 'main.txt')).writeAsStringSync('one\ntwo\n');
    git(w.app, ['init', '-q']);
    git(w.app, ['config', 'core.autocrlf', 'false']);
    git(w.app, ['add', '-A']);
    git(w.app, ['commit', '-q', '-m', 'app']);

    w.db = AppDatabase.memory();
    w.db.execute('PRAGMA foreign_keys = OFF;');
    final created = w.at.toIso8601String();
    for (final (id, kind, name) in [
      (
        'local',
        Platform.isWindows ? 'windowsNative' : 'localPosix',
        'this machine',
      ),
      ('box', 'ssh', 'build-box'),
    ]) {
      w.db.execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        'VALUES (?, ?, ?, ?);',
        [id, kind, name, created],
      );
    }
    w.addRepository('r1', w.hub);
    w.addRepository('r2', '/srv/app', environmentId: 'box');
    w.db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at, '
      'executable_by_user) VALUES (?, ?, ?, ?, ?, 0);',
      ['a1', AgentIds.claudeCode, 'local', '/usr/local/bin/claude', created],
    );
    w.addSession('s1', conversation: 'cli-1', workingDirectory: w.hub);
    if (holdS1) w.held.add('s1');

    w.data = DataService(w.db, clock: () => w.at);
    w.client = w.data.open((batch) => w.told.addAll(batch.changes));
    w.client.handle(const DataSubscribe());
    w.checkpoints = DaemonCheckpoints(
      database: w.db,
      data: w.data,
      heldHere: w.held.contains,
      runnerFactory: w.runners,
      clock: () => w.at,
      newId: () => 'ckpt${++w._ids}',
      hold: hold,
      log: w.log.add,
    )..start(w.statuses.stream);
    w.data.checkpointWork = w.checkpoints.handle;
    return w;
  }

  Future<void> close() async {
    await checkpoints.close();
    await statuses.close();
    db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a git file a moment longer; the OS cleans temp.
    }
  }

  void addRepository(
    String id,
    String path, {
    String environmentId = 'local',
  }) => db.execute(
    'INSERT INTO repositories '
    '(id, project_id, name, environment_id, path, created_at) '
    'VALUES (?, ?, ?, ?, ?, ?);',
    [id, 'p1', 'repo-$id', environmentId, path, at.toIso8601String()],
  );

  void addSession(
    String id, {
    String repositoryId = 'r1',
    String? conversation,
    String? workingDirectory,
    String environmentId = 'local',
    String? title,
    SessionStatus status = SessionStatus.running,
  }) => SessionDao(db).insert(
    Session(
      id: id,
      repositoryId: repositoryId,
      agentInstallationId: 'a1',
      title: title ?? 'session $id',
      useWorktree: false,
      status: status,
      createdAt: at,
      externalSessionId: conversation,
      workingDirectory: workingDirectory == null
          ? null
          : EnvironmentPath(
              environmentId: environmentId,
              path: workingDirectory,
            ),
    ),
  );

  EnvironmentPath local(String path) =>
      EnvironmentPath(environmentId: 'local', path: path);

  /// One hook the endpoint took, as Claude Code posts it.
  AgentHookEvent hookEvent(
    String event, [
    Map<String, Object?> body = const {},
    String conversation = 'cli-1',
    String? header,
  ]) => AgentHookEvent(
    agent: AgentIds.claudeCode,
    event: event,
    sessionHeader: header,
    receivedAt: at,
    body: {'session_id': conversation, 'hook_event_name': event, ...body},
  );

  /// What the endpoint does with one hook: the recorder first, and — as the
  /// server's hook path does — waits for the answer the agent gets.
  Future<void> hook(
    String event, [
    Map<String, Object?> body = const {},
    String conversation = 'cli-1',
    String? header,
  ]) => checkpoints.hook(hookEvent(event, body, conversation, header));

  /// The daemon's own status for a row it holds.
  void status(String sessionId, AgentActivityStatus status) => statuses.add(
    HostedAgentStatus(
      sessionId: sessionId,
      report: AgentStatusReport(
        agentId: AgentIds.claudeCode,
        sessionId: 'cli-$sessionId',
        status: status,
        observedAt: at,
        source: AgentStatusSource.hook,
      ),
    ),
  );

  Map<String, Object?> edit(String file) => {
    'tool_name': 'Edit',
    'tool_input': {'file_path': file},
  };

  /// A turn by hooks alone: the prompt, then Stop.
  Future<void> turn({
    String prompt = 'Do it',
    String conversation = 'cli-1',
  }) async {
    await hook('UserPromptSubmit', {'prompt': prompt}, conversation);
    await hook('Stop', const {}, conversation);
    await settle(sessionOf(conversation));
  }

  String sessionOf(String conversation) =>
      SessionDao(db).getByExternalSessionId(conversation)!.id;

  Future<void> settle([String sessionId = 's1']) async {
    await checkpoints.recorder.settled(sessionId);
    await checkpoints.recorder.queued(sessionId, () async {});
  }

  List<Checkpoint> rows([String sessionId = 's1']) =>
      CheckpointDao(db).forSession(sessionId);

  List<String> reasons([String sessionId = 's1']) => [
    for (final c in rows(sessionId)) c.reason.name,
  ];

  List<Checkpoint> ofRepo(String path, [String sessionId = 's1']) => [
    for (final c in rows(sessionId))
      if (c.repository.path == path) c,
  ];

  /// Waits (a hang guard, not a bound) until [count] checkpoints of [path].
  Future<void> untilCheckpoints(String path, int count) async {
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (ofRepo(path).length < count) {
      if (DateTime.now().isAfter(deadline)) return;
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Asks [request] as a client over the envelope, and answers its value —
  /// or throws the refusal the envelope carried.
  Future<R> ask<R>(DataRequest<R> request) async {
    final answer = client.handleJson(DataEnvelope.request(1, request));
    expect(answer, isA<Future<Map<String, Object?>>>(), reason: 'later');
    final json = jsonDecode(jsonEncode(await answer)) as Map<String, Object?>;
    return DataEnvelope.readAnswer(json, request).value;
  }

  /// Writes the checkpoint settings as a client does.
  void setSettings(CheckpointSettings settings) => client.handle(
    PreferenceSet(kCheckpointSettingsKey, jsonEncode(settings.toJson())),
  );
}
