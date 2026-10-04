import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart' show AgentPaneLaunch;
import 'package:karmashala/src/features/terminal/application/client_intents.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show OpenSessionTab, SessionAgentChanged;
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneId;
import 'package:karmashala_terminal_core/pane_lifecycle.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// A switch closes the outgoing agent's terminal — live, ended or never
/// shown — keeps the chat tab in front, and opens a terminal agent's pane
/// behind it. A Restart on a pane left from an earlier agent never relaunches
/// that agent.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows
      ..insert(agentInstallation(id: 'cc'))
      ..insert(
        agentInstallation(
          id: 'cx',
          agentId: AgentIds.codex,
          path: r'C:\Users\me\.bin\codex.exe',
        ),
      )
      ..insert(
        agentInstallation(
          id: 'acp',
          agentId: AgentIds.claudeAcp,
          path: r'C:\Users\me\.bin\claude-agent-acp.exe',
        ),
      );
    db.server.sessionRows.insert(
      session(
        id: 's1',
        agentInstallationId: 'cc',
        status: SessionStatus.running,
      ),
    );
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db, data: await server.override()),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    addTearDown(container.dispose);
  });

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  List<String> panes() => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      ...tab.layout.panes,
  ];

  String? front() => container
      .read(terminalSessionsControllerProvider)
      .activeTab
      ?.focusedPaneId;

  String openAgent(String agentId) => terminals()
      .openAgentTab(
        AgentPaneLaunch(agentId: agentId, executable: agentId, sessionId: 's1'),
      )
      .paneId;

  Future<void> switchTo(String installation) => container
      .read(sessionHandoffServiceProvider)
      .switchAgent(sessionId: 's1', targetInstallationId: installation);

  test('to a terminal agent: the old pane closes, the new one opens behind '
      'the chat, which stays in front', () async {
    final old = openAgent(AgentIds.claudeCode);
    terminals().openChatTab('s1');

    await switchTo('cx');

    expect(panes(), isNot(contains(old)));
    expect(terminals().instanceFor(old), isNull);
    final fresh = panes().where((p) => p != chatPaneId('s1')).single;
    expect(
      terminals().instanceFor(fresh)!.agentLaunch!.agentId,
      AgentIds.codex,
    );
    expect(front(), chatPaneId('s1'));
    expect(container.read(sessionsDataProvider).getById('s1')!.paneId, fresh);
  });

  test('an ended pane and one never shown go too — nothing is left saying '
      '"Session ended" with a Restart for the old agent', () async {
    final ended = openAgent(AgentIds.claudeCode);
    final behind = openAgent(AgentIds.claudeCode);
    (terminals().instanceFor(ended)! as FakeTerminalInstance).exitWith(0);
    (terminals().instanceFor(behind)! as FakeTerminalInstance)
            .livenessNotifier
            .value =
        PaneLiveness.restored;

    await switchTo('cx');

    expect(panes(), isNot(contains(ended)));
    expect(panes(), isNot(contains(behind)));
    expect(front(), chatPaneId('s1'));
  });

  test(
    'Codex to Claude to Codex leaves one terminal, the current agent\'s',
    () async {
      db.server.sessionRows.put(
        db.server.sessionRows
            .getById('s1')!
            .copyWith(agentInstallationId: 'cx'),
      );
      openAgent(AgentIds.codex);
      await switchTo('cc');
      await switchTo('cx');

      final terminalPanes = panes()
          .where((p) => p != chatPaneId('s1'))
          .toList();
      expect(terminalPanes, hasLength(1));
      expect(
        terminals().instanceFor(terminalPanes.single)!.agentLaunch!.agentId,
        AgentIds.codex,
      );
      expect(front(), chatPaneId('s1'));
    },
  );

  test('to an ACP agent: no terminal at all, the chat in front', () async {
    final old = openAgent(AgentIds.claudeCode);

    await switchTo('acp');

    expect(panes(), [chatPaneId('s1')]);
    expect(terminals().instanceFor(old), isNull);
    expect(front(), chatPaneId('s1'));
    expect(container.read(sessionsDataProvider).getById('s1')!.paneId, isNull);
  });

  test('Restart on a pane from the agent the session left closes it rather '
      'than relaunch that agent', () async {
    final stale = openAgent(AgentIds.claudeCode);
    (terminals().instanceFor(stale)! as FakeTerminalInstance).exitWith(0);
    db.server.sessionRows.put(
      db.server.sessionRows.getById('s1')!.copyWith(agentInstallationId: 'cx'),
    );
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    final result = await container
        .read(explorerActionsProvider)
        .reopenSwitchedPane(stale);

    expect(result, isNotNull);
    expect(
      terminals().instanceFor(stale)?.agentLaunch?.agentId,
      isNot(AgentIds.claudeCode),
    );
  });

  test('a pane of the row\'s own agent is left to its Restart', () async {
    final own = openAgent(AgentIds.claudeCode);
    (terminals().instanceFor(own)! as FakeTerminalInstance).exitWith(0);

    final result = await container
        .read(explorerActionsProvider)
        .reopenSwitchedPane(own);

    expect(result, isNull);
    expect(panes(), contains(own));
  });

  List<String> terminalPanes() =>
      panes().where((p) => p != chatPaneId('s1')).toList();

  test('a switch made from another client and the server asking to show it '
      'leave one chat tab and one terminal; Quick open twice adds '
      'nothing', () async {
    final follow = container.listen(sessionSwitchFollowerProvider, (_, _) {});
    addTearDown(follow.close);
    container.read(clientIntentsProvider);
    final old = openAgent(AgentIds.claudeCode);
    terminals().openChatTab('s1');
    // The server ended the old agent; its pane has noticed.
    (terminals().instanceFor(old)! as FakeTerminalInstance).exitWith(0);
    db.server.sessionRows.put(
      db.server.sessionRows.getById('s1')!.copyWith(agentInstallationId: 'cx'),
    );

    // As an MCP `session_handoff inPlace` tells it: the switch, and a tab.
    server.writeAsAnotherClient(const [
      SessionAgentChanged(
        sessionId: 's1',
        agentInstallationId: 'cx',
        spans: [],
      ),
    ]);
    server.sessionWork.tellIntent(
      const OpenSessionTab(
        sessionId: 's1',
        title: 'Limit test',
        launch: AgentPaneLaunch(
          agentId: AgentIds.codex,
          executable: 'codex',
          sessionId: 's1',
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(terminalPanes(), hasLength(1));
    expect(
      terminals().instanceFor(terminalPanes().single)!.agentLaunch!.agentId,
      AgentIds.codex,
    );
    expect(panes().where((p) => p == chatPaneId('s1')), hasLength(1));

    for (var i = 0; i < 2; i++) {
      await container.read(explorerActionsProvider).openNative('s1');
      await Future<void>.delayed(Duration.zero);
    }
    expect(terminalPanes(), hasLength(1));
    expect(panes().where((p) => p == chatPaneId('s1')), hasLength(1));
  });

  test('a terminal asked for twice on one session is one pane', () {
    final first = openAgent(AgentIds.codex);
    final second = openAgent(AgentIds.codex);
    expect(second, first);
    expect(panes(), [first]);
  });

  test('a switch made from another client closes the old terminal here and '
      'opens the new agent behind the chat', () async {
    final sub = container.listen(sessionSwitchFollowerProvider, (_, _) {});
    addTearDown(sub.close);
    final old = openAgent(AgentIds.claudeCode);
    db.server.sessionRows.put(
      db.server.sessionRows.getById('s1')!.copyWith(agentInstallationId: 'cx'),
    );

    server.writeAsAnotherClient(const [
      SessionAgentChanged(
        sessionId: 's1',
        agentInstallationId: 'cx',
        spans: [],
      ),
    ]);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(terminals().instanceFor(old), isNull);
    final fresh = panes().where((p) => p != chatPaneId('s1')).single;
    expect(
      terminals().instanceFor(fresh)!.agentLaunch!.agentId,
      AgentIds.codex,
    );
    expect(front(), chatPaneId('s1'));
  });
}
