import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneId;
import 'package:karmashala_terminal_core/profiles.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// Deleting a session closes its tabs and panes — a chat tab and a terminal
/// pane alike — and a bulk delete does it as one layout change.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    final data = await server.override();
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows
      ..insert(
        agentInstallation(
          id: 'acp',
          agentId: AgentIds.claudeAcp,
          path: r'C:\Users\me\.bin\claude-agent-acp.exe',
        ),
      )
      ..insert(
        agentInstallation(
          id: 'cx',
          agentId: AgentIds.codex,
          path: r'C:\Users\me\.bin\codex.exe',
        ),
      );
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
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

  void chatSession(String id) {
    db.server.sessionRows.insert(
      session(id: id, agentInstallationId: 'acp', status: SessionStatus.idle),
    );
    terminals().openChatTab(id);
  }

  String terminalSession(String id) {
    terminals().openTab(TerminalProfile.powerShell);
    final pane = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    db.server.sessionRows
      ..insert(session(id: id, agentInstallationId: 'cx'))
      ..updatePaneId(id, pane);
    return pane;
  }

  testWidgets('deleting one session closes its tab', (tester) async {
    chatSession('a');
    chatSession('b');
    await tester.pump();

    await container
        .read(sessionActionsProvider)
        .deleteNative('a', deleteFromCli: false);
    await tester.pump();

    expect(panes(), isNot(contains(chatPaneId('a'))));
    expect(panes(), contains(chatPaneId('b')));
  });

  testWidgets('a bulk delete closes every tab and pane of the sessions, in '
      'one layout change', (tester) async {
    chatSession('a');
    final shell = terminalSession('t');
    chatSession('keep');
    await tester.pump();
    var changes = 0;
    container.listen(
      terminalSessionsControllerProvider.select((s) => s.tabs),
      (_, _) => changes++,
    );

    container
        .read(sessionActionsProvider)
        .deleteSessionsFromWorkspace(
          natives: [
            db.server.sessionRows.getById('a')!,
            db.server.sessionRows.getById('t')!,
          ],
        );
    await tester.pump();

    expect(panes(), [chatPaneId('keep')]);
    expect(panes(), isNot(contains(shell)));
    expect(changes, 1);
  });
}
