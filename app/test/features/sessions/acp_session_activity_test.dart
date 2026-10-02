import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneId;

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **What an ACP session's chat tab dot says in each state.** The tab has no
/// process of ours behind it, so the dot is the row's status and the agent's
/// own word as the server keeps it: idle, working or awaiting approval
/// while the row runs — for a window that was there and for one that
/// arrives later — and nothing once the row has ended, when the tab's
/// liveness marker takes the slot back.
void main() {
  late TestMachine db;
  late FakeDataServer server;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(
        id: 'acp',
        agentId: AgentIds.claudeAcp,
        path: r'C:\Users\me\.bin\claude-agent-acp.exe',
      ),
    );
  });

  void row(SessionStatus status, {String id = 'acp-1'}) => db.server.sessionRows
      .insert(session(id: id, agentInstallationId: 'acp', status: status));

  void said(
    AgentActivityStatus status, {
    String id = 'acp-1',
    AgentWaitKind? waiting,
  }) => server.attention.statusOf(
    id,
    status,
    agentId: AgentIds.claudeAcp,
    sessionId: 'agent-session',
    source: AgentStatusSource.protocol,
    waiting: waiting ?? AgentWaitKind.unrecorded,
  );

  Future<ProviderContainer> connect({String id = 'acp-1'}) async {
    final container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
      ],
    );
    addTearDown(container.dispose);
    container.listen(
      paneAgentActivityProvider(chatPaneId(id)),
      (previous, next) {},
    );
    await pumpEventQueue();
    return container;
  }

  AgentActivityStatus? dot(
    ProviderContainer container, {
    String id = 'acp-1',
  }) => container.read(paneAgentActivityProvider(chatPaneId(id)));

  test('a running row shows the agent\'s own word, as it moves', () async {
    row(SessionStatus.running);
    said(AgentActivityStatus.idle);
    final container = await connect();
    expect(dot(container), AgentActivityStatus.idle);

    said(AgentActivityStatus.working);
    await pumpEventQueue();
    expect(dot(container), AgentActivityStatus.working);

    said(AgentActivityStatus.awaitingApproval, waiting: AgentWaitKind.approval);
    await pumpEventQueue();
    expect(dot(container), AgentActivityStatus.awaitingApproval);

    said(AgentActivityStatus.idle);
    await pumpEventQueue();
    expect(dot(container), AgentActivityStatus.idle);
  });

  test('a window arriving after the session started reads the current word '
      'from the server\'s greeting', () async {
    row(SessionStatus.running);
    said(AgentActivityStatus.working);
    final container = await connect();

    expect(dot(container), AgentActivityStatus.working);
    final report = container
        .read(agentSessionStatusProvider('acp-1'))
        .asData!
        .value;
    expect(report.source, AgentStatusSource.protocol);
    expect(report.sessionId, 'agent-session');
  });

  test('a running row the server has said nothing about yet is unknown, '
      'not absent: the agent is still starting', () async {
    row(SessionStatus.running);
    final container = await connect();
    expect(dot(container), AgentActivityStatus.unknown);
  });

  test('an ended row shows no agent word, whatever was last said', () async {
    const ended = [
      SessionStatus.completed,
      SessionStatus.failed,
      SessionStatus.cancelled,
      SessionStatus.unknown,
    ];
    for (final status in ended) {
      row(status, id: status.name);
      said(AgentActivityStatus.idle, id: status.name);
    }
    final container = await connect(id: 'completed');
    for (final status in ended) {
      expect(dot(container, id: status.name), isNull, reason: status.name);
    }
  });

  test('the process ending moves the dot off with the row, and the status '
      'the server lets go of is not missed', () async {
    row(SessionStatus.running);
    said(AgentActivityStatus.idle);
    final container = await connect();
    expect(dot(container), AgentActivityStatus.idle);

    db.server.sessionRows.updateStatus('acp-1', SessionStatus.completed);
    server.attention.forget('acp-1');
    await pumpEventQueue();

    expect(dot(container), isNull);
  });
}
