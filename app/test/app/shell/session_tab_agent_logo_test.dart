import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/presentation/agent_logo.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
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

/// **A session's tab wears its agent's mark** before its title — a terminal
/// session's and a chat session's alike — and follows a switch of agent. A tab
/// holding no session keeps what it showed.
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

  TerminalSessionsController terminals() =>
      container.read(terminalSessionsControllerProvider.notifier);

  String activePane() => container
      .read(terminalSessionsControllerProvider)
      .activeTab!
      .layout
      .panes
      .single;

  /// A chat session: the server runs it over ACP and its tab is a chat pane.
  void seedChatSession() => db.server.sessionRows.insert(
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

  /// A terminal session, in a pane of ours.
  void seedTerminalSession() {
    terminals().openTab(TerminalProfile.powerShell);
    db.server.sessionRows
      ..insert(session(id: 'cx-1', agentInstallationId: 'cx'))
      ..updatePaneId('cx-1', activePane());
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: WorkbenchView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder chip(String title) => find.widgetWithText(TerminalTabChip, title);

  List<String> logosIn(WidgetTester tester, Finder chip) => [
    for (final logo in tester.widgetList<AgentLogo>(
      find.descendant(of: chip, matching: find.byType(AgentLogo)),
    ))
      logo.agentId,
  ];

  testWidgets('a terminal session tab and a chat session tab each wear their '
      "agent's mark; a plain shell's tab wears none", (tester) async {
    seedChatSession();
    seedTerminalSession();
    terminals().openTab(TerminalProfile.powerShell);
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);

    expect(find.byType(SessionTranscriptView), findsOneWidget);
    // Both shell tabs are titled for their shell, so each chip is addressed
    // by its place in the one strip, which is the controller's tab order.
    final tabs = container.read(terminalSessionsControllerProvider).tabs;
    final chips = find.byType(TerminalTabChip);
    expect(chips, findsNWidgets(3));
    final marks = {
      for (var i = 0; i < tabs.length; i++)
        tabs[i].layout.panes.single: logosIn(tester, chips.at(i)),
    };
    expect(marks[chatPaneId('acp-1')], [AgentIds.claudeAcp]);
    final shellPanes = marks.keys.where((p) => p != chatPaneId('acp-1'));
    final cxPane = db.server.sessionRows.getById('cx-1')!.paneId;
    expect(marks[cxPane], [AgentIds.codex]);
    expect(marks[shellPanes.firstWhere((p) => p != cxPane)], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets("the mark follows the session's agent when it is switched", (
    tester,
  ) async {
    seedChatSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);
    expect(logosIn(tester, chip('Over ACP')), [AgentIds.claudeAcp]);

    db.server.sessionRows.put(
      db.server.sessionRows
          .getById('acp-1')!
          .copyWith(agentInstallationId: 'cx'),
    );
    await tester.pumpAndSettle();

    expect(logosIn(tester, chip('Over ACP')), [AgentIds.codex]);
  });

  group('the width budget', () {
    Future<void> pumpChip(WidgetTester tester, double width) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: WorkbenchTabChip(
                    selected: true,
                    onTap: () {},
                    label: 'A session title',
                    mark: const SizedBox.square(
                      key: ValueKey('mark'),
                      dimension: 13,
                    ),
                    trailing: const SizedBox.square(dimension: 20),
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('the narrowest window tab still wears the mark', (
      tester,
    ) async {
      await pumpChip(tester, kMinTabWidth);
      expect(find.byKey(const ValueKey('mark')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a region tab too narrow for it keeps its title instead', (
      tester,
    ) async {
      await pumpChip(tester, kMinRegionTabWidth);
      expect(find.byKey(const ValueKey('mark')), findsNothing);
      expect(find.text('A session title'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
