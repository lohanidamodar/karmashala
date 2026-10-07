import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionEndRequest, SessionStarted;
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **A launch the server answers with no terminal** — an agent it speaks to
/// over ACP and runs itself — is shown as a chat tab, decided by the
/// installation's adapter and never by the agent's id. Closing that tab asks
/// the server nothing: the session is its to keep running.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late ProviderContainer container;

  final acpInstallation = agentInstallation(
    id: 'acp',
    agentId: AgentIds.claudeAcp,
    path: r'C:\Users\me\.bin\claude-agent-acp.exe',
  );

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(acpInstallation);
    server.installationRows.insert(agentInstallation(id: 'pty'));
    container = ProviderContainer(
      overrides: [
        await server.override(),
        ...fakeTerminalOverrides(machine: db),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
        agentSessionStatusProvider.overrideWith(
          (ref, id) => const Stream<AgentStatusReport>.empty(),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<SessionLaunchResult> launchOverAcp() => container
      .read(sessionLauncherProvider)
      .launch(
        SessionLaunchRequest(
          repository: repository(),
          installation: acpInstallation,
          title: 'Over ACP',
          purpose: SessionPurpose.newSession,
        ),
      );

  test('a session started over ACP opens as a chat tab', () async {
    final launched = await launchOverAcp();

    final state = container.read(terminalSessionsControllerProvider);
    expect(launched.tabId, isNotNull);
    expect(state.tabs.map((tab) => tab.id), [launched.tabId]);
    expect(state.tabs.single.layout.panes, [chatPaneId(launched.session.id)]);
    // No terminal of ours: the launcher names no pane, and nothing runs here.
    expect(launched.paneId, isNull);
    expect(
      container.read(paneSessionsProvider).paneOf(launched.session.id),
      chatPaneId(launched.session.id),
    );
    expect(
      container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(chatPaneId(launched.session.id)),
      isNull,
    );
    expect(server.sessionWork.running, contains(launched.session.id));
  });

  test(
    'shown again, the same tab comes forward rather than a second',
    () async {
      final launched = await launchOverAcp();
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);

      final shown = await container
          .read(sessionLauncherProvider)
          .showStarted(SessionStarted(session: launched.session));

      final state = container.read(terminalSessionsControllerProvider);
      expect(shown.tabId, launched.tabId);
      expect(state.activeTabId, launched.tabId);
      expect(state.tabs, hasLength(2));
    },
  );

  test(
    'closing the chat tab leaves the session running at the server',
    () async {
      final launched = await launchOverAcp();

      container
          .read(terminalSessionsControllerProvider.notifier)
          .closeTab(launched.tabId!);

      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
      expect(server.sessionWork.running, contains(launched.session.id));
      expect(server.sessionWork.asked.whereType<SessionEndRequest>(), isEmpty);
    },
  );

  test('a PTY session still gets its terminal pane, not a chat tab', () async {
    final launched = await container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repository(),
            installation: agentInstallation(id: 'pty'),
            title: 'In a terminal',
            purpose: SessionPurpose.newSession,
          ),
        );

    expect(launched.paneId, isNotNull);
    expect(isChatPane(launched.paneId!), isFalse);
    expect(
      container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor(launched.paneId!),
      isNotNull,
    );
  });

  group('kept here: started, and no tab opens or takes focus', () {
    for (final (name, installation) in [
      ('over ACP', acpInstallation),
      ('in a terminal', agentInstallation(id: 'pty')),
    ]) {
      test(name, () async {
        final terminals = container.read(
          terminalSessionsControllerProvider.notifier,
        );
        final working = terminals.openTab(TerminalProfile.powerShell);

        final launched = await container
            .read(sessionLauncherProvider)
            .launch(
              SessionLaunchRequest(
                repository: repository(),
                installation: installation,
                title: 'Kept here',
                purpose: SessionPurpose.newSession,
                openTab: false,
              ),
            );

        final state = container.read(terminalSessionsControllerProvider);
        expect(launched.tabId, isNull);
        expect(launched.paneId, isNull);
        expect(state.tabs.map((t) => t.id), [working]);
        expect(state.activeTabId, working);
        expect(server.sessionWork.running, contains(launched.session.id));
      });
    }

    test('its tab can still be shown later', () async {
      final launched = await container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: acpInstallation,
              title: 'Kept here',
              purpose: SessionPurpose.newSession,
              openTab: false,
            ),
          );
      expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);

      final shown = await container
          .read(sessionLauncherProvider)
          .showStarted(SessionStarted(session: launched.session));
      final state = container.read(terminalSessionsControllerProvider);
      expect(state.tabs.map((t) => t.id), [shown.tabId]);
      expect(state.activeTabId, shown.tabId);
    });
  });
}
