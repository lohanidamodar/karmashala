import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/app/shell/shell_compact_bar.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/sessions/application/delivery_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_chat_source.dart';
import 'package:karmashala/src/features/sessions/application/session_handoff_service.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_transcript_view.dart';
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

/// **The phone's header names the session on screen.** A session with no pane
/// of ours opens as a chat and leaves the tab in front where it was; the
/// header named that tab while the chat below was another session's.
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
        // A phone: its sessions open on their chat, the default it ships with.
        ...fakeTerminalOverrides(machine: db, openSessionsInChat: true),
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

  /// A session in a pane of ours, as every in-app agent session is.
  void seedInAPane(String id, String title) {
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
      ..insert(session(id: id, agentInstallationId: 'pty', title: title))
      ..updatePaneId(id, paneId);
  }

  Future<void> pumpPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: CompactWorkbenchScope(
              child: Column(
                children: [
                  ShellTabSwitcher(),
                  WorkbenchFaceToggle(),
                  Expanded(child: WorkbenchView()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String header(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(ShellTabSwitcher),
          matching: find.byType(Text),
        ),
      )
      .map((t) => t.data)
      .join();

  testWidgets('the header names the session whose chat is showing, not the '
      'tab left behind it', (tester) async {
    seedInAPane('probe', 'Probe fixes');
    // No pane of ours: it opens as a chat on a phone, and the tab stays.
    db.server.sessionRows.insert(
      session(
        id: 'achiver',
        agentInstallationId: 'pty',
        title: 'achiver',
        status: SessionStatus.completed,
      ),
    );
    container.read(selectedSessionIdProvider.notifier).select('probe');
    await pumpPhone(tester);
    expect(header(tester), isNot('achiver'));

    container.read(selectedSessionIdProvider.notifier).select('achiver');
    await tester.pumpAndSettle();

    final shown = tester.widget<SessionTranscriptView>(
      find.byType(SessionTranscriptView),
    );
    expect(shown.sessionId, 'achiver');
    expect(header(tester), 'achiver');
    expect(tester.takeException(), isNull);
  });
}
