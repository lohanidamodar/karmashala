import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/presentation/agent_logo.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **The session bar leads with its session's agent**, so it is clear which
/// agent you are typing to — at every width the bar takes, following a switch
/// of agent. A plain shell's foot has no agent to show.
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

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
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
                ? const CompactWorkbenchScope(child: workbench)
                : workbench,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The agents the session bar shows, by the key its mark carries.
  List<String> barMarks(WidgetTester tester) => [
    for (final logo in tester.widgetList<AgentLogo>(
      find.descendant(
        of: find.byKey(const ValueKey('session-bar-agent')),
        matching: find.byType(AgentLogo),
      ),
    ))
      logo.agentId,
  ];

  for (final (name, size, compact) in [
    ('one status line', const Size(1440, 900), false),
    ('facts over controls', const Size(700, 900), false),
    ('phone', const Size(390, 844), true),
  ]) {
    testWidgets("$name: the bar leads with the chat session's agent, and "
        'follows a switch', (tester) async {
      seedChatSession();
      container.read(selectedSessionIdProvider.notifier).select('acp-1');
      await pump(tester, size: size, compact: compact);

      expect(barMarks(tester), [AgentIds.claudeAcp]);

      db.server.sessionRows.put(
        db.server.sessionRows
            .getById('acp-1')!
            .copyWith(agentInstallationId: 'cx'),
      );
      await tester.pumpAndSettle();

      expect(barMarks(tester), [AgentIds.codex]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets("a terminal session's bar leads with its agent", (tester) async {
    terminals().openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .activeTab!
        .layout
        .panes
        .single;
    db.server.sessionRows
      ..insert(session(id: 'cx-1', agentInstallationId: 'cx'))
      ..updatePaneId('cx-1', paneId);
    container.read(selectedSessionIdProvider.notifier).select('cx-1');
    await pump(tester);

    expect(barMarks(tester), [AgentIds.codex]);
    // The mark is the bar's only word on the agent, so it is named on hover.
    final name = container
        .read(agentRegistryProvider)
        .displayNameFor(AgentIds.codex);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-bar-agent')),
        matching: find.byTooltip(name),
      ),
      findsOneWidget,
    );
  });

  testWidgets("a plain shell's foot shows no agent", (tester) async {
    terminals().openTab(TerminalProfile.powerShell);
    await pump(tester);

    expect(find.byKey(const ValueKey('session-bar-agent')), findsNothing);
    expect(find.byType(AgentLogo), findsNothing);
  });
}
