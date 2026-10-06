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

/// A terminal the server closes — `terminal_close`, another window, a phone —
/// leaves every window, though the window shows it under a pane id of its
/// own and the server names it by session.
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
    server.installationRows.insert(
      agentInstallation(
        id: 'cc',
        agentId: AgentIds.claudeCode,
        path: r'C:\Users\me\.bin\claude.exe',
      ),
    );
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
      ],
    );
    addTearDown(container.dispose);
    container.listen(closedTerminalTabsCloserProvider, (_, _) {});
  });

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);
  List<String> panes() => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      ...tab.layout.panes,
  ];

  /// What the window does when told to show a session the server started: an
  /// agent tab under a pane id of the window's own, named on the row.
  String agentSession(String id) {
    db.server.sessionRows.insert(
      session(id: id, agentInstallationId: 'cc', status: SessionStatus.running),
    );
    final opened = terminals().openAgentTab(
      AgentPaneLaunch(
        agentId: AgentIds.claudeCode,
        executable: r'C:\Users\me\.bin\claude.exe',
        sessionId: id,
        title: 'Chat $id',
      ),
    );
    db.server.sessionRows.updatePaneId(id, opened.paneId);
    return opened.paneId;
  }

  testWidgets('a session\'s terminal closed by the server closes its tab and '
      'its chat tab here', (tester) async {
    final pane = agentSession('child');
    terminals().openChatTab('child');
    final keep = agentSession('keep');
    await tester.pump();
    expect(pane, isNot('session-child'), reason: 'the window names its own');

    server.terminals.remove('karmashala_child');
    await tester.pump();

    expect(panes(), [keep]);
    expect(panes(), isNot(contains(chatPaneId('child'))));
  });

  testWidgets('a shell closed by the server closes its pane here', (
    tester,
  ) async {
    terminals().openTab(TerminalProfile.powerShell);
    final shell = panes().single;
    final keep = agentSession('keep');
    await tester.pump();

    server.terminals.remove('karmashala_local_$shell');
    await tester.pump();

    expect(panes(), [keep]);
  });

  testWidgets('a record the server only pruned leaves the tab', (tester) async {
    final pane = agentSession('child');
    await tester.pump();

    server.terminals.remove('karmashala_child', closed: false);
    await tester.pump();

    expect(panes(), [pane]);
  });
}
