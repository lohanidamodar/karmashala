import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionEndRequest;
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneId;
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **An ACP session is a chat session** (ACP design, C5): the workbench opens
/// its conversation as a tab of its own — a chat pane, with no process behind
/// it, since the server owns the agent — and offers no terminal to toggle to.
/// A PTY session beside it keeps both faces.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    data = await server.override();
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
    server.installationRows.insert(agentInstallation(id: 'pty'));
    container = ProviderContainer(
      overrides: [
        data,
        ...fakeTerminalOverrides(machine: db),
        // Both transcript sources poll a real timer or ask the fake server for
        // what it does not serve; the workbench only needs a conversation.
        sessionTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        sessionChatTranscriptProvider.overrideWith(
          (ref, id) => Stream.value(const <TranscriptMessage>[]),
        ),
        availableSystemTerminalsProvider.overrideWith(
          (ref) async => const <SystemTerminal>[],
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        sessionDeliveryProvider.overrideWith(
          (ref, _) async => SessionDelivery.unknown,
        ),
        sessionContinuationProvider.overrideWith(
          (ref, _) => SessionContinuation(
            targets: const [],
            plan: SessionForkPlan.decide(descriptor: null, agentName: 'ACP'),
          ),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeAcp,
              sessionId: id,
              status: AgentActivityStatus.idle,
              observedAt: testTime,
              source: AgentStatusSource.none,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  /// A session the server runs over ACP: no pane of ours, and no CLI id —
  /// the server's rows are the conversation.
  void seedAcpSession() => db.server.sessionRows.insert(
    Session(
      id: 'acp-1',
      repositoryId: 'r1',
      agentInstallationId: 'acp',
      title: 'Over ACP',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: testTime,
    ),
  );

  /// A PTY session in a pane of ours, as every in-app agent session is.
  void seedPtySessionInAPane() {
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    terminals.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    db.server.sessionRows
      ..insert(session(id: 'pty-1', agentInstallationId: 'pty'))
      ..updatePaneId('pty-1', paneId);
  }

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    bool compact = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const workbench = WorkbenchView();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: compact
                ? const CompactWorkbenchScope(
                    child: Column(
                      children: [
                        WorkbenchFaceToggle(),
                        Expanded(child: workbench),
                      ],
                    ),
                  )
                : workbench,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The chip the strip draws for the ACP session's tab.
  Finder acpChip() => find.widgetWithText(TerminalTabChip, 'Over ACP');

  testWidgets('an ACP session selected opens as a chat tab, with no terminal '
      'to toggle', (tester) async {
    seedAcpSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);

    // A real tab, named for the row, holding the chat pane and nothing else.
    expect(acpChip(), findsOneWidget);
    final tabs = container.read(terminalSessionsControllerProvider).tabs;
    expect(tabs, hasLength(1));
    expect(tabs.single.layout.panes, [chatPaneId('acp-1')]);
    // Drawn by the pane stack as the tab's body, not beside the tabs.
    expect(find.byType(SessionTranscriptView), findsOneWidget);
    expect(find.byType(TerminalPaneStack), findsOneWidget);
    expect(find.byTooltip('Terminal view'), findsNothing);
    expect(find.byTooltip('Chat view'), findsNothing);
    // No switcher either: there is no second surface to keep alive.
    expect(find.byKey(kWorkbenchSurfaces), findsNothing);
    expect(find.textContaining('No chat view'), findsNothing);
    expect(find.textContaining('No terminal of ours'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone the same chat, and the app bar offers no toggle', (
    tester,
  ) async {
    seedAcpSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester, size: const Size(390, 844), compact: true);

    expect(find.byType(SessionTranscriptView), findsOneWidget);
    expect(find.byTooltip('Terminal view'), findsNothing);
    expect(find.byTooltip('Chat view'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting the ACP session again brings its tab forward, '
      'never a second one', (tester) async {
    seedAcpSession();
    seedPtySessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);
    expect(find.byType(TerminalTabChip), findsNWidgets(2));

    container.read(selectedSessionIdProvider.notifier).select('pty-1');
    await tester.pumpAndSettle();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await tester.pumpAndSettle();

    expect(find.byType(TerminalTabChip), findsNWidgets(2));
    expect(acpChip(), findsOneWidget);
    expect(find.byType(SessionTranscriptView), findsOneWidget);
  });

  testWidgets('the chat tab switches with a terminal tab like any two tabs', (
    tester,
  ) async {
    seedAcpSession();
    seedPtySessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final chatTab = container
        .read(terminalSessionsControllerProvider)
        .activeTabId!;
    final shellTab = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.id != chatTab)
        .id;

    // To the terminal: its surface, its toggle, and the chat put away.
    terminals.activateTab(shellTab);
    await tester.pumpAndSettle();
    expect(find.byType(SessionTranscriptView), findsNothing);
    expect(find.byTooltip('Chat view'), findsOneWidget);
    expect(acpChip(), findsOneWidget);

    // And back, by the chip, as a person would.
    await tester.tap(acpChip());
    await tester.pumpAndSettle();
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      chatTab,
    );
    expect(find.byType(SessionTranscriptView), findsOneWidget);
    expect(find.byTooltip('Chat view'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the chat tab leaves the session running at the server', (
    tester,
  ) async {
    seedAcpSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);
    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final tabId = container
        .read(terminalSessionsControllerProvider)
        .activeTabId!;

    terminals.closeTab(tabId);
    await tester.pumpAndSettle();

    expect(acpChip(), findsNothing);
    expect(find.byType(SessionTranscriptView), findsNothing);
    expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
    // A view closed, not a session ended: the server was asked nothing.
    expect(server.sessionWork.asked.whereType<SessionEndRequest>(), isEmpty);
    expect(
      db.server.sessionRows.getById('acp-1')!.status,
      SessionStatus.running,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a PTY session keeps its terminal and the toggle', (
    tester,
  ) async {
    seedPtySessionInAPane();
    container.read(selectedSessionIdProvider.notifier).select('pty-1');
    await pump(tester);

    expect(find.byType(TerminalPaneStack), findsOneWidget);
    expect(find.byTooltip('Chat view'), findsOneWidget);
    expect(find.byTooltip('Terminal view'), findsOneWidget);
    expect(find.byType(SessionTranscriptView), findsNothing);
  });
}
