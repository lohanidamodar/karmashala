import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_acp/karmashala_acp.dart' show AuthMethod;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/automations/daemon_agents.dart';
import 'package:karmashala_host/src/sessions/session_ends_with_server.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// A host that hands the runtime's word to the daemon's status keeper, as
/// `ServerAcpHost` does, and keeps a copy for assertions.
class _StatusHost extends RecordingHost {
  _StatusHost(this._status);

  final DaemonAgentStatus _status;

  @override
  void status(String sessionId, AgentStatusReport report) {
    super.status(sessionId, report);
    _status.report(sessionId, report);
  }
}

/// **What an ACP session's row and activity say in each state** — the
/// owner's report was that both read "unknown". While the runtime runs the
/// row is `running` and the activity is the agent's own word; an end is an
/// end (`completed`, `failed` with the reason, `cancelled` on request), and
/// a restart finds no runtime to adopt, so a row left `running` is
/// `completed` — never `unknown`, which is for a process somebody could still
/// be running out of sight. A PTY row keeps its `unknown`.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  late AppDatabase database;
  late Directory temp;
  late FakePtyLauncher pty;
  late SessionRegistry registry;
  late LifecycleFeed feed;
  late SessionStatusRecording recording;
  late DaemonAgentStatus status;
  late List<String> written;
  late List<(String, Map<String, Object?>?)> published;
  late _StatusHost host;

  SessionStatusRecording recordingOver(LifecycleFeed feed) =>
      SessionStatusRecording(
        feed,
        database,
        clock: () => DateTime.now().toUtc(),
        onWritten: (id) =>
            written.add('$id ${SessionDao(database).getById(id)!.status.name}'),
        resolveUnknown: sessionEndsWithServer(
          rows: CheckoutRows(database),
          agents: const DaemonAgents(),
        ),
      );

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_rows_test');
    final local = Platform.isWindows ? 'windowsNative' : 'localPosix';
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['local', local, 'Here', '$t0'],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, '
      'path, created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop', 'local', temp.path, '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'acp1', AgentIds.claudeAcp, 'local', 'npx.cmd', '$t0', 1, //
        'cc1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1,
      ],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
    feed = LifecycleFeed(registry, clock: () => DateTime.now().toUtc());
    written = [];
    published = [];
    recording = recordingOver(feed);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (id, body) => published.add((id, body)),
      interval: const Duration(hours: 1),
    );
    host = _StatusHost(status);
  });

  tearDown(() async {
    await status.close();
    await recording.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  void row(String id, {required String installation, SessionStatus? status}) =>
      SessionDao(database).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: installation,
          title: 'Work',
          useWorktree: false,
          status: status ?? SessionStatus.created,
          createdAt: t0,
        ),
      );

  SessionStatus statusOf(String id) => SessionDao(database).getById(id)!.status;

  AgentStatusReport? activityOf(String id) => status.statusOf(id)?.report;

  /// An ACP runtime for row [id], opened in the registry and started.
  Future<(AcpSessionRuntime, FakeAcpProcess)> start(
    String id, {
    List<FakeTurn> turns = const [],
  }) async {
    final process = FakeAcpProcess(
      FakeAcpAgent(sessionIdPrefix: 'agent-session', turns: turns),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      sessionId: id,
      agentId: AgentIds.claudeAcp,
    );
    registry.openAcp('karmashala_$id', runtime);
    await runtime.start();
    await pump();
    return (runtime, process);
  }

  test('while the runtime runs, the row is running and the activity is the '
      'agent\'s own word — idle, working, awaiting approval — for a client '
      'that was there and for one that arrives later', () async {
    row('s1', installation: 'acp1');
    recording.start();
    final (runtime, process) = await start(
      's1',
      turns: const [
        FakeTurn([
          FakeStep.toolCall(
            toolCallId: 'c1',
            title: 'Run tests',
            permissionOptions: fakePermissionOptions,
          ),
          FakeStep.message('Done.'),
        ]),
      ],
    );

    expect(statusOf('s1'), SessionStatus.running);
    expect(written, ['s1 running']);
    final idle = activityOf('s1')!;
    expect(idle.status, AgentActivityStatus.idle);
    expect(idle.source, AgentStatusSource.protocol);
    // The keeper answers the current protocol status to a watcher's
    // snapshot: a client connecting now reads the same word.
    expect(status.snapshot().map((s) => s['sessionId']), contains('s1'));
    // A tick keeps a running ACP session; it has no screen to read.
    status.tick();
    expect(activityOf('s1')!.status, AgentActivityStatus.idle);

    await runtime.send('go');
    expect(activityOf('s1')!.status, AgentActivityStatus.working);
    while (!runtime.hasOpenPermission) {
      await pump();
    }
    final asking = activityOf('s1')!;
    expect(asking.status, AgentActivityStatus.awaitingApproval);
    expect(asking.waiting, AgentWaitKind.approval);
    expect(asking.toolAsk?.toolName, 'Run tests');

    await runtime.answerPermission(approve: true);
    expect(await runtime.awaitTurn(), isNotNull);
    expect(activityOf('s1')!.status, AgentActivityStatus.idle);
    expect(statusOf('s1'), SessionStatus.running);
    expect(process.killed, isFalse);
  });

  test('the process exiting on its own ends the row: completed on 0, failed '
      'otherwise with the agent\'s failure published, then the status is '
      'let go of', () async {
    row('s1', installation: 'acp1');
    row('s2', installation: 'acp1');
    recording.start();
    final (_, clean) = await start('s1');
    final (_, dying) = await start('s2');

    await clean.die(0);
    await pump();
    expect(statusOf('s1'), SessionStatus.completed);

    await dying.die(3);
    await pump();
    expect(statusOf('s2'), SessionStatus.failed);
    final failure = host.statuses.lastWhere((r) => r.sessionId.isNotEmpty);
    expect(failure.status, AgentActivityStatus.failed);
    expect(failure.failureReason, 'exit');
    expect(failure.evidence.single, contains('exit code 3'));
    expect(activityOf('s2')!.status, AgentActivityStatus.failed);

    // The next tick lets go of both: nothing runs them any more.
    status.tick();
    expect(activityOf('s1'), isNull);
    expect(activityOf('s2'), isNull);
    expect(published.where((p) => p.$2 == null).map((p) => p.$1), ['s1', 's2']);
    expect(written, ['s1 running', 's2 running', 's1 completed', 's2 failed']);
  });

  test('a stop asked for ends the row as cancelled, as a terminal\'s End '
      'does', () async {
    row('s1', installation: 'acp1');
    recording.start();
    final (_, process) = await start('s1');

    await registry.close('karmashala_s1');
    await pump();

    expect(process.killed, isTrue);
    expect(statusOf('s1'), SessionStatus.cancelled);
    expect(registry.findProcess('karmashala_s1'), isNull);
  });

  test('the server stopping ends an ACP row as completed, not unknown: the '
      'agent went with it', () async {
    row('s1', installation: 'acp1');
    recording.start();
    await start('s1');

    await registry.shutdown();
    await pump();

    expect(statusOf('s1'), SessionStatus.completed);
    expect(written, ['s1 running', 's1 completed']);
  });

  test('at start, an ACP row left running by the server before is completed '
      'and a PTY row left running is unknown, by the installation\'s '
      'capability', () async {
    row('acp', installation: 'acp1', status: SessionStatus.running);
    row('pty', installation: 'cc1', status: SessionStatus.running);
    row('done', installation: 'acp1', status: SessionStatus.failed);

    // A fresh server: no runtime of the old one survives for it to adopt.
    recording.start();

    expect(statusOf('acp'), SessionStatus.completed);
    expect(statusOf('pty'), SessionStatus.unknown);
    expect(statusOf('done'), SessionStatus.failed);
    expect(written, unorderedEquals(['acp completed', 'pty unknown']));
    expect(status.statusOf('acp'), isNull);
    // A row this server runs again is running, as before.
    await start('acp');
    expect(statusOf('acp'), SessionStatus.running);
  });

  test('a start the agent refuses — a login demanded — ends the row failed '
      'through the lifecycle, never completed: the runtime ended without '
      'a code, and the reason is a failure', () async {
    row('s1', installation: 'acp1');
    recording.start();
    final process = FakeAcpProcess(
      FakeAcpAgent(
        requireAuthentication: true,
        authMethods: const [
          AuthMethod(id: 'a', name: 'A'),
          AuthMethod(id: 'b', name: 'B'),
        ],
      ),
    );
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: temp.path,
      host: host,
      sessionId: 's1',
      agentId: AgentIds.claudeAcp,
    );
    registry.openAcp('karmashala_s1', runtime);

    await expectLater(
      runtime.start(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('asks to be logged in first'),
        ),
      ),
    );
    await pump();

    expect(runtime.lifecycle.hasEnded, isTrue);
    expect(runtime.lifecycle.exitCode, isNull);
    expect(statusOf('s1'), SessionStatus.failed);
    expect(written, ['s1 running', 's1 failed']);
    // The launcher's own `failed`, landing after: the same word.
    SessionDao(database).updateStatus('s1', SessionStatus.failed);
    expect(statusOf('s1'), SessionStatus.failed);
  });
}
