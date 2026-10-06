import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/phone_routes.dart';
import 'package:karmashala/src/app/shell/shell_compact_bar.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/terminal/application/system_terminal_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionStarted, TabReveal;
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import 'package:karmashala_ui/theme.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **A session another session started opens behind**: the tab in front, the
/// keyboard and the selection stay where the person left them, and the new
/// tab says it is new until it is looked at.
void main() {
  late TestMachine db;
  late ProviderContainer container;

  setUp(() async {
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
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
      ..insert(agentInstallation(id: 'pty'));
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
            plan: SessionForkPlan.decide(descriptor: null, agentName: 'CLI'),
          ),
        ),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => Stream.value(
            AgentStatusReport(
              agentId: AgentIds.claudeCode,
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

  void sized(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// A session row in a shell pane of ours, the tab in front.
  String seedInFront(String id) {
    terminals().openTab(TerminalProfile.powerShell);
    final tab = container.read(terminalSessionsControllerProvider).activeTab!;
    db.server.sessionRows
      ..insert(session(id: id, agentInstallationId: 'pty', title: 'Parent'))
      ..updatePaneId(id, tab.layout.panes.single);
    return tab.id;
  }

  testWidgets('desktop: the strip marks the tab new, the keyboard stays, and '
      'the mark goes when the tab is opened', (tester) async {
    sized(tester, const Size(1440, 900));
    final front = seedInFront('p1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: WorkbenchView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus;
    expect(find.byKey(const ValueKey('tab-new-mark')), findsNothing);

    final opened = terminals().openAgentTab(
      const AgentPaneLaunch(
        agentId: AgentIds.claudeCode,
        executable: 'claude',
        sessionId: 'c1',
        title: 'Child',
      ),
      behind: OpenBehind(afterTabId: front),
    );
    await tester.pumpAndSettle();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.activeTabId, front);
    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(find.byKey(const ValueKey('tab-new-mark')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('New')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tab-new-mark')));
    await tester.pumpAndSettle();

    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      opened.tabId,
    );
    expect(find.byKey(const ValueKey('tab-new-mark')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone: a chat an agent started opens behind, and the phone '
      'stays on the session it shows', (tester) async {
    sized(tester, const Size(390, 844));
    final front = seedInFront('p1');
    container.read(selectedSessionIdProvider.notifier).select('p1');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: CompactWorkbenchScope(
              child: Column(
                children: [
                  ShellTabSwitcher(),
                  Expanded(child: WorkbenchView()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final workbenchOpen = container.read(phoneWorkbenchProvider);
    final child = session(
      id: 'c2',
      agentInstallationId: 'acp',
      title: 'Child',
      status: SessionStatus.running,
    ).copyWith(parentSessionId: 'p1');
    db.server.sessionRows.insert(child);

    await container
        .read(sessionLauncherProvider)
        .showStarted(
          SessionStarted(session: child),
          showing: TabReveal.background,
        );
    await tester.pumpAndSettle();

    final state = container.read(terminalSessionsControllerProvider);
    expect(state.activeTabId, front);
    expect(container.read(selectedSessionIdProvider), 'p1');
    expect(container.read(phoneWorkbenchProvider), workbenchOpen);
    expect(state.unseenTabIds, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
