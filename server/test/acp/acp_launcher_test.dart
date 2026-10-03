import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:karmashala_acp/karmashala_acp.dart' show AuthMethod, StopReason;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_auth.dart' show AcpStartAuth;
import 'package:karmashala_host/src/acp/acp_login_required.dart';
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/automations/daemon_agents.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/session_ends_with_server.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

/// The launcher's ACP branch (design C4): an installation whose adapter has
/// `acp != null` is started as a runtime in the registry, never a PTY; the
/// row learns the agent's session id, the opening message is the first
/// prompt, and a start that fails leaves the row as a failed spawn would.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late Directory temp;
  late List<AcpSessionStart> starts;
  late FakeAcpProcess process;
  late RecordingHost host;
  late SessionStatusRecording recording;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_launcher_test');
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
    // The rows are written as the server writes them: by the launcher, and
    // by the lifecycle of what the registry holds, whichever lands last.
    recording = SessionStatusRecording(
      LifecycleFeed(registry, clock: () => DateTime.now().toUtc()),
      database,
      clock: () => DateTime.now().toUtc(),
      resolveUnknown: sessionEndsWithServer(
        rows: CheckoutRows(database),
        agents: const DaemonAgents(),
      ),
    )..start();
    starts = [];
    process = FakeAcpProcess(
      FakeAcpAgent(
        sessionIdPrefix: 'agent-session',
        turns: const [
          FakeTurn([FakeStep.message('Hello back')]),
        ],
      ),
    );
    host = RecordingHost();
  });

  tearDown(() async {
    await recording.close();
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  /// The server's factory, with the fake agent in place of a process.
  AcpSessionRuntime factory(AcpSessionStart start) {
    starts.add(start);
    return runtimeOver(
      process,
      database: database,
      workingDirectory: start.directory.path,
      host: host,
      sessionId: start.sessionId,
      agentId: start.agentId,
      spec: start.spec,
      mcpUrl: start.mcpUrl,
      risk: start.risk,
      resumeSessionId: start.resumeSessionId,
    );
  }

  HostedAgentLauncher launcher({
    bool withRuntimes = true,
    AcpStartAuth Function(AgentInstallation, AcpLaunchSpec)? acpAuth,
    void Function(String sessionId)? onRowWritten,
  }) {
    final rows = CheckoutRows(database);
    return HostedAgentLauncher(
      registry: registry,
      sessions: SessionDao(database),
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
      now: () => t0,
      newId: () => 's1',
      hostEnvironment: const {},
      environmentOf: rows.environment,
      acpRuntimes: withRuntimes ? factory : null,
      acpAuth: acpAuth,
      onRowWritten: onRowWritten,
      windows: false,
    );
  }

  Session row(String id) => SessionDao(database).getById(id)!;

  test('an ACP installation starts a runtime under karmashala_<id>, not a '
      'PTY; the row names the agent\'s session and the prompt is the first '
      'turn', () async {
    final rows = CheckoutRows(database);
    final started = await launcher().startDetailed(
      HostedLaunch(
        repository: rows.repository('r1')!,
        installation: rows.installation('acp1')!,
        title: 'Cart',
        prompt: 'Fix the cart',
        permissionMode: 'mode=acceptEdits',
      ),
    );
    expect(pty.started, isEmpty);
    expect(registry.find('karmashala_s1'), isNull);
    final runtime = registry.findAcp('karmashala_s1');
    expect(runtime, isNotNull);
    // No launch: a launch is what a pane attaches a terminal to, and this
    // session has none — the app opens it in the chat view instead.
    expect(started.launch, isNull);
    expect(
      started.attachNotice,
      contains("Karmashala's tools were not handed"),
    );

    final start = starts.single;
    expect(start.sessionId, 's1');
    expect(start.hostSessionId, 'karmashala_s1');
    expect(start.executable, 'npx.cmd');
    expect(start.directory.path, temp.path);
    expect(start.variables, {'KARMASHALA_SESSION_ID': 's1'});
    expect(start.risk, PermissionRisk.acceptEdits);
    expect(start.resumeSessionId, isNull);
    expect(start.mcpUrl, isNull);

    expect(row('s1').externalSessionId, 'agent-session');
    expect(started.session.externalSessionId, 'agent-session');
    expect(row('s1').status, SessionStatus.running);
    expect(await runtime!.awaitTurn(), StopReason.endTurn);
    expect(
      process.agent.prompts.single.single.toJson()['text'],
      'Fix the cart',
    );
    final messages = SessionMessageDao(database).listAfter('s1');
    expect(messages.map((m) => m.text), ['Fix the cart', 'Hello back']);
  });

  test(
    'a resume hands the row\'s conversation to the runtime, which loads it',
    () async {
      final rows = CheckoutRows(database);
      SessionDao(database).insert(
        Session(
          id: 'old',
          repositoryId: 'r1',
          agentInstallationId: 'acp1',
          title: 'Old',
          useWorktree: false,
          status: SessionStatus.completed,
          createdAt: t0,
          externalSessionId: 'agent-session-9',
        ),
      );
      final started = await launcher().startDetailed(
        HostedLaunch(
          repository: rows.repository('r1')!,
          installation: rows.installation('acp1')!,
          title: 'Old',
          resuming: SessionDao(database).getById('old'),
        ),
      );
      expect(starts.single.resumeSessionId, 'agent-session-9');
      expect(
        process.agent.loadSessionParams.single['sessionId'],
        'agent-session-9',
      );
      expect(process.agent.newSessionParams, isEmpty);
      expect(started.session.externalSessionId, 'agent-session-9');
      expect(row('old').status, SessionStatus.running);
      expect(registry.findAcp('karmashala_old'), isNotNull);
    },
  );

  test('a resume of a conversation the agent no longer holds goes on as a '
      'fresh one in the same row, and says so', () async {
    // Seen live: GitHub Copilot answered session/load with -32002 "Session
    // … not found", and the resume gave up with nothing sent.
    process = FakeAcpProcess(
      FakeAcpAgent(sessionIdPrefix: 'fresh', holdsNoConversations: true),
    );
    final rows = CheckoutRows(database);
    SessionDao(database).insert(
      Session(
        id: 'old',
        repositoryId: 'r1',
        agentInstallationId: 'acp1',
        title: 'Old',
        useWorktree: false,
        status: SessionStatus.failed,
        createdAt: t0,
        externalSessionId: 'gone-9',
      ),
    );
    final started = await launcher().startDetailed(
      HostedLaunch(
        repository: rows.repository('r1')!,
        installation: rows.installation('acp1')!,
        title: 'Old',
        resuming: SessionDao(database).getById('old'),
      ),
    );
    expect(process.agent.loadSessionParams.single['sessionId'], 'gone-9');
    expect(process.agent.newSessionParams, hasLength(1));
    expect(started.session.externalSessionId, 'fresh');
    expect(row('old').externalSessionId, 'fresh');
    expect(row('old').status, SessionStatus.running);
    expect(started.attachNotice, contains('no longer holds this conversation'));
  });

  test('a PTY agent is untouched by the branch', () async {
    final rows = CheckoutRows(database);
    await launcher().start(
      HostedLaunch(
        repository: rows.repository('r1')!,
        installation: rows.installation('cc1')!,
        title: 'Terminal',
      ),
    );
    expect(pty.started, hasLength(1));
    expect(starts, isEmpty);
    expect(registry.find('karmashala_s1'), isNotNull);
  });

  test('with no runtime factory the start is refused in words and the row '
      'is left failed', () async {
    final rows = CheckoutRows(database);
    await expectLater(
      launcher(withRuntimes: false).start(
        HostedLaunch(
          repository: rows.repository('r1')!,
          installation: rows.installation('acp1')!,
          title: 'Cart',
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('given no runtime'),
        ),
      ),
    );
    expect(row('s1').status, SessionStatus.failed);
    expect(registry.findProcess('karmashala_s1'), isNull);
  });

  test('a runtime that cannot start leaves the row failed — through the '
      'launcher and through the lifecycle of its ended process alike — and '
      'the registry holding that process', () async {
    process = FakeAcpProcess(
      FakeAcpAgent(
        requireAuthentication: true,
        authMethods: const [
          AuthMethod(id: 'a', name: 'A'),
          AuthMethod(id: 'b', name: 'B'),
        ],
      ),
    );
    final rows = CheckoutRows(database);
    final written = <String>[];
    recording.changes.listen((c) => written.add(c.to.name));
    await expectLater(
      launcher().start(
        HostedLaunch(
          repository: rows.repository('r1')!,
          installation: rows.installation('acp1')!,
          title: 'Cart',
        ),
      ),
      throwsA(
        isA<AcpLoginRequired>().having(
          (e) => e.message,
          'message',
          contains('asks to be logged in first'),
        ),
      ),
    );
    // The lifecycle's write, whether it lands before or after the
    // launcher's, says failed too — never completed.
    await pump();
    expect(row('s1').status, SessionStatus.failed);
    expect(written, everyElement('failed'));
    final ended = registry.findProcess('karmashala_s1')!.lifecycle;
    expect(ended.hasEnded, isTrue);
    expect(ended.exitCode, isNull, reason: 'it never ran a turn to exit');
  });

  test('a resume the agent refuses leaves the row failed through both '
      'writers, not back at the status it had', () async {
    process = FakeAcpProcess(
      FakeAcpAgent(
        requireAuthentication: true,
        supportsLoadSession: false,
        authMethods: const [
          AuthMethod(id: 'a', name: 'A'),
          AuthMethod(id: 'b', name: 'B'),
        ],
      ),
    );
    SessionDao(database).insert(
      Session(
        id: 'old',
        repositoryId: 'r1',
        agentInstallationId: 'acp1',
        title: 'Old',
        useWorktree: false,
        status: SessionStatus.completed,
        createdAt: t0,
        externalSessionId: 'agent-session-9',
      ),
    );
    final rows = CheckoutRows(database);
    final written = <String>[];
    recording.changes.listen((c) => written.add(c.to.name));
    final byLauncher = <SessionStatus>[];
    await expectLater(
      launcher(onRowWritten: (id) => byLauncher.add(row(id).status)).start(
        HostedLaunch(
          repository: rows.repository('r1')!,
          installation: rows.installation('acp1')!,
          title: 'Old',
          resuming: SessionDao(database).getById('old'),
        ),
      ),
      throwsA(isA<AcpLoginRequired>()),
    );
    await pump();
    expect(row('old').status, SessionStatus.failed);
    expect(written, everyElement('failed'));
    expect(byLauncher.last, SessionStatus.failed);
  });
  test('the login remembered for the installation is the method a start '
      'authenticates with, and its key reaches the agent', () async {
    process = FakeAcpProcess(
      FakeAcpAgent(
        requireAuthentication: true,
        authMethods: const [
          AuthMethod(id: 'a', name: 'A'),
          AuthMethod(id: 'b', name: 'B'),
        ],
      ),
    );
    final asked = <String>[];
    final rows = CheckoutRows(database);
    await launcher(
      acpAuth: (installation, spec) {
        asked.add(installation.id);
        return (
          spec: spec.withAuthMethod('b'),
          variables: const {'API_KEY': 'k'},
        );
      },
    ).start(
      HostedLaunch(
        repository: rows.repository('r1')!,
        installation: rows.installation('acp1')!,
        title: 'Cart',
      ),
    );
    expect(asked, ['acp1']);
    expect(process.agent.authenticatedWith, 'b');
    expect(starts.single.spec.authMethodId, 'b');
    expect(starts.single.variables['API_KEY'], 'k');
    expect(starts.single.variables['KARMASHALA_SESSION_ID'], 's1');
  });
}
