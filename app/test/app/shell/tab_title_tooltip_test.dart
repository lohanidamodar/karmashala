import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';
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

/// **Hovering a tab names it in full** — titles are cut to fit — and a
/// session's tab names its agent too. Not over the close button, which has
/// its own, and not while the tab is being dragged.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;

  const longTitle =
      'Fix the login flow so the session survives a token refresh';

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

  void seedChatSession() => db.server.sessionRows.insert(
    Session(
      id: 'acp-1',
      repositoryId: 'r1',
      agentInstallationId: 'acp',
      title: longTitle,
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: testTime,
    ),
  );

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

  /// How many times [message] is drawn. A shown tooltip adds one; its overlay
  /// sits under the chip in the element tree, so it cannot be told apart by
  /// ancestry.
  int drawn(String message) => find.text(message).evaluate().length;

  Future<TestGesture> hover(WidgetTester tester, Offset at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(at);
    await tester.pump();
    // Past the theme's wait, so a tooltip that would show has shown.
    await tester.pump(const Duration(seconds: 1));
    return mouse;
  }

  Finder chipTitle(String title) => find.descendant(
    of: find.byType(TerminalTabChip),
    matching: find.text(title),
  );

  testWidgets(
    "a session tab's tooltip is its full title, its agent and where it runs",
    (tester) async {
      seedChatSession();
      container.read(selectedSessionIdProvider.notifier).select('acp-1');
      await pump(tester);
      final agent = container
          .read(agentRegistryProvider)
          .displayNameFor(AgentIds.claudeAcp);

      expect(drawn('$longTitle · $agent · Windows'), 0);
      await hover(tester, tester.getCenter(chipTitle(longTitle)));

      expect(drawn('$longTitle · $agent · Windows'), 1);
    },
  );

  testWidgets("a plain shell tab's tooltip is its title", (tester) async {
    container
        .read(terminalSessionsControllerProvider.notifier)
        .openTab(TerminalProfile.powerShell);
    await pump(tester);
    final tabId = container
        .read(terminalSessionsControllerProvider)
        .activeTabId!;
    final title = container.read(terminalTabTitleProvider(tabId));

    final before = drawn(title);
    await hover(tester, tester.getCenter(chipTitle(title)));

    expect(drawn(title), before + 1);
  });

  testWidgets("over the close button only the button's tooltip shows", (
    tester,
  ) async {
    seedChatSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);
    final close = find.descendant(
      of: find.byType(TerminalTabChip),
      matching: find.byTooltip('Close tab'),
    );

    await hover(tester, tester.getCenter(close.first));

    expect(drawn('Close tab'), 1);
    expect(find.textContaining('$longTitle · '), findsNothing);
  });

  testWidgets('no title tooltip while the tab is being dragged', (
    tester,
  ) async {
    seedChatSession();
    container.read(selectedSessionIdProvider.notifier).select('acp-1');
    await pump(tester);

    final mouse = await tester.startGesture(
      tester.getCenter(chipTitle(longTitle)),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(4, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(4, 0));
    await tester.pump(const Duration(seconds: 1));

    // The drag's feedback draws the title alone; only the tooltip adds the agent.
    expect(find.textContaining('$longTitle · '), findsNothing);
    await mouse.up();
    await tester.pumpAndSettle();
  });
}
