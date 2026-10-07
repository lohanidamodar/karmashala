import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/app/shell/phone_ask_banner.dart';
import 'package:karmashala/src/app/shell/shell_compact_bar.dart';
import 'package:karmashala/src/features/explorer/application/agent_state_providers.dart';
import 'package:karmashala/src/features/explorer/application/agent_states.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
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

/// **Every phone surface about "the session" reads the one on screen.** A
/// session with no pane of ours opens as a chat and leaves the tab in front
/// where it was; the ask banner and the session panels followed that tab.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late Override data;
  late ProviderContainer container;
  var asking = <String, NeedsYouSource>{};

  setUp(() async {
    asking = {};
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
        needsYouProvider.overrideWith((ref) => asking),
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
                  PhoneAskBanner(),
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

  testWidgets('a question in the session shown, not the tab behind it, is '
      'not bannered, and the panels describe the session shown', (
    tester,
  ) async {
    seedInAPane('probe', 'Probe fixes');
    // No pane of ours: it opens as a chat on a phone, and the tab stays.
    db.server.sessionRows.insert(
      session(
        id: 'achiver',
        agentInstallationId: 'pty',
        title: 'achiver',
        status: SessionStatus.idle,
      ),
    );
    asking = {
      'achiver': const NeedsYouSource(label: 'achiver', imported: false),
    };
    container.read(selectedSessionIdProvider.notifier).select('probe');
    await pumpPhone(tester);
    container.read(selectedSessionIdProvider.notifier).select('achiver');
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SessionTranscriptView>(find.byType(SessionTranscriptView))
          .sessionId,
      'achiver',
    );
    expect(
      container.read(terminalSessionsControllerProvider).activeTab,
      isNotNull,
      reason: 'the tab is still in front, behind the chat',
    );
    expect(container.read(panelSessionIdProvider), 'achiver');
    expect(find.byKey(const ValueKey('phone-ask-banner')), findsNothing);

    // The tab's own session asking is off screen, and is bannered.
    asking = {
      ...asking,
      'probe': const NeedsYouSource(label: 'Probe fixes', imported: false),
    };
    container.invalidate(needsYouProvider);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('phone-ask-banner')), findsOneWidget);
    expect(find.textContaining('Probe fixes'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
