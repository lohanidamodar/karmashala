import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart' show PathProbe;
import 'package:karmashala_acp/karmashala_acp.dart'
    show ConfigOption, SessionMode, SessionModeState;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/acp/acp_runtimes.dart';
import 'package:karmashala_host/src/acp/acp_session_runtime.dart';
import 'package:karmashala_host/src/automations/daemon_checkout_facts.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/server_session_launcher.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'acp_fixture.dart';

final class _Everywhere implements PathProbe {
  const _Everywhere();
  @override
  bool? fileExists(String path) => true;
  @override
  bool isLink(String path) => false;
  @override
  String? linkTarget(String path) => null;
}

/// **An ended ACP session comes back through `sessions.resume`** — the one
/// request a client makes of the server to continue a row (the chat
/// composer's resume-on-send, the explorer's Resume): the runtime loads the
/// row's conversation over `session/load` where the agent can, announcing
/// its modes and config options; an agent that cannot starts a fresh
/// conversation in the same row and says so; one already running is
/// answered as it is.
void main() {
  final t0 = DateTime.utc(2026, 10, 2, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late Directory temp;
  late List<AcpSessionStart> starts;
  late FakeAcpAgent agent;
  late RecordingHost host;

  const modes = SessionModeState(
    currentModeId: 'default',
    availableModes: [
      SessionMode(id: 'default', name: 'Ask'),
      SessionMode(id: 'plan', name: 'Plan'),
    ],
  );
  const options = [
    ConfigOption(
      id: 'model',
      name: 'Model',
      type: 'select',
      currentValue: 'fast',
    ),
  ];

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    temp = Directory.systemTemp.createTempSync('acp_resume_test');
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
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['acp1', AgentIds.claudeAcp, 'local', 'npx.cmd', '$t0', 1],
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
    registry = SessionRegistry(launcher: FakePtyLauncher());
    starts = [];
    agent = FakeAcpAgent(
      sessionIdPrefix: 'agent-session',
      modes: modes,
      configOptions: options,
    );
    host = RecordingHost();
  });

  tearDown(() async {
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  AcpSessionRuntime factory(AcpSessionStart start) {
    starts.add(start);
    return runtimeOver(
      FakeAcpProcess(agent),
      database: database,
      workingDirectory: start.directory.path,
      host: host,
      sessionId: start.sessionId,
      agentId: start.agentId,
      spec: start.spec,
      resumeSessionId: start.resumeSessionId,
    );
  }

  ServerSessionLauncher launches() {
    final rows = CheckoutRows(database);
    return ServerSessionLauncher(
      launcher: HostedAgentLauncher(
        registry: registry,
        sessions: SessionDao(database),
        mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
        now: () => t0,
        newId: () => 'new',
        hostEnvironment: const {},
        environmentOf: rows.environment,
        acpRuntimes: factory,
        windows: false,
      ),
      registry: registry,
      sessions: SessionDao(database),
      rows: rows,
      facts: DaemonCheckoutFacts(rows, windows: Platform.isWindows),
      installationsIn: DataService(database).installationsIn,
      pathProbe: const _Everywhere(),
      directoryPresent: (_) => true,
    );
  }

  Session row(String id) => SessionDao(database).getById(id)!;

  test('resuming an ended row loads its conversation and hands back the '
      'modes and options the agent announced on load', () async {
    final started = await launches().resume('old');

    expect(started.adopted, isFalse);
    expect(started.launch, isNull, reason: 'no terminal to attach');
    expect(starts.single.resumeSessionId, 'agent-session-9');
    expect(agent.loadSessionParams.single['sessionId'], 'agent-session-9');
    expect(agent.newSessionParams, isEmpty);
    expect(row('old').status, SessionStatus.running);
    expect(row('old').externalSessionId, 'agent-session-9');
    // The one notice is about the tools (no MCP endpoint here), not about
    // the conversation: it was continued, not started afresh.
    expect(
      started.workingDirectoryNotice,
      isNot(contains('fresh conversation')),
    );

    final announced = host.modes.last;
    expect(announced.sessionId, 'old');
    expect(announced.currentModeId, isNotNull);
    expect(announced.availableModes.map((m) => m.id), ['default', 'plan']);
    final config = host.configOptions.last;
    expect(config.sessionId, 'old');
    expect(config.options.single.id, 'model');
    expect(config.options.single.currentValue, 'fast');

    final runtime = registry.findAcp('karmashala_old')!;
    expect(runtime.lifecycle.hasEnded, isFalse);
    expect(host.statuses.last.status, AgentActivityStatus.idle);
    expect(host.statuses.last.detail, 'session/load');
  });

  test('an agent that cannot load a session starts a fresh conversation in '
      'the same row, with the notice', () async {
    agent = FakeAcpAgent(
      sessionIdPrefix: 'agent-session',
      supportsLoadSession: false,
    );

    final started = await launches().resume('old');

    expect(agent.loadSessionParams, isEmpty);
    expect(agent.newSessionParams, hasLength(1));
    expect(started.session.id, 'old');
    expect(row('old').status, SessionStatus.running);
    expect(row('old').externalSessionId, isNot('agent-session-9'));
    expect(
      started.workingDirectoryNotice,
      contains('fresh conversation in the same session'),
    );
  });

  test('resuming a row the server already runs is answered as it is: no '
      'second runtime', () async {
    final server = launches();
    await server.resume('old');

    final again = await server.resume('old');

    expect(again.adopted, isTrue);
    expect(again.session.id, 'old');
    expect(starts, hasLength(1));
    expect(agent.loadSessionParams, hasLength(1));
  });
}
