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

/// An ended session archived from anywhere — this window, the server's
/// `session_archive`, another client — has its tabs and panes closed here.
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
    container.listen(archivedSessionTabsCloserProvider, (_, _) {});
  });

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);
  List<String> panes() => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      ...tab.layout.panes,
  ];

  void chatSession(String id) {
    db.server.sessionRows.insert(
      session(
        id: id,
        agentInstallationId: 'acp',
        status: SessionStatus.completed,
      ),
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
      ..insert(
        session(
          id: id,
          agentInstallationId: 'cx',
          status: SessionStatus.completed,
        ),
      )
      ..updatePaneId(id, pane);
    return pane;
  }

  testWidgets('an archive made by the server closes the tab here', (
    tester,
  ) async {
    chatSession('child');
    chatSession('keep');
    await tester.pump();

    // What the server's session_archive writes when a parent archives it.
    db.server.sessionRows.markArchived('child', testTime);
    await tester.pump();

    expect(panes(), [chatPaneId('keep')]);
  });

  testWidgets('a bulk archive closes every tab and pane of the sessions, in '
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

    await container.read(sessionActionsProvider).archiveSessions(['a', 't']);
    await tester.pump();

    expect(panes(), [chatPaneId('keep')]);
    expect(panes(), isNot(contains(shell)));
    expect(changes, 1);
  });

  testWidgets('unarchiving reopens nothing', (tester) async {
    chatSession('a');
    await tester.pump();
    await container.read(sessionActionsProvider).archiveSessions(['a']);
    await tester.pump();

    await container.read(sessionActionsProvider).unarchiveSessions(['a']);
    await tester.pump();

    expect(panes(), isEmpty);
  });

  testWidgets('an archive with no workbench built leaves it unbuilt', (
    tester,
  ) async {
    db.server.sessionRows.insert(
      session(
        id: 'a',
        agentInstallationId: 'acp',
        status: SessionStatus.completed,
      ),
    );
    await tester.pump();

    db.server.sessionRows.markArchived('a', testTime);
    await tester.pump();

    expect(container.exists(terminalSessionsControllerProvider), isFalse);
  });
}
