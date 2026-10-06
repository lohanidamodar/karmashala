import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/client_intents.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart' show TerminalProfile;
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_terminal_core/geometry.dart' show chatPaneId;
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_terminal_runtime/instances.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import 'fake_instance.dart';

/// What the server asks this window to show (slice 5b; 3d's hosted-run panes,
/// generalised): a tab on a terminal or a session the server runs, attached
/// to it — against a real host over a real socket, so the pane finds the
/// session by the id both sides spell the same way.
void main() {
  // An attached pane's output is coalesced per frame; on Windows it can
  // arrive before a test ends.
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late HostPaths paths;
  late SessionRegistry registry;

  setUp(() async {
    // Short: a unix socket path must fit in 104 bytes on macOS.
    home = Directory.systemTemp.createTempSync('kci');
    paths = HostPaths(Directory('${home.path}/.k'))..ensureDirectory();
    registry = SessionRegistry(launcher: FakePtyLauncher());
    final server = HostServer(registry: registry, ptyLibrary: 'fake');
    final listener = await UnixSocketHostListener.bind(paths.socketPath);
    final serving = server.listen(listener);
    addTearDown(() async {
      await serving.cancel();
      await listener.close();
      await registry.shutdown();
      try {
        home.deleteSync(recursive: true);
      } on FileSystemException {
        // A socket node can still be held on Windows.
      }
    });
  });

  Future<(ProviderContainer, FakeDataServer)> start() async {
    final server = FakeDataServer();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(
          data: await server.override(),
          realHostedPanes: true,
        ),
        localHostSessionAccessProvider.overrideWithValue(
          LocalHostSessionAccess(
            paths: paths,
            executable: LocalHostExecutable(executableDirectory: home.path),
            startServe: (_) async =>
                throw StateError('a pane must never start a host'),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(clientIntentsProvider);
    return (container, server);
  }

  int tabsWith(ProviderContainer container, String paneId) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.contains(paneId)) tab,
  ].length;

  void runOnHost(String hostSessionId) => registry.open(
    hostSessionId,
    const PtySpawnRequest(argv: ['sh'], environment: {}, columns: 80, rows: 24),
  );

  test(
    'a terminal the server runs opens as a tab attached to it, once',
    () async {
      final (container, server) = await start();
      runOnHost(hostedRunSessionId('hosted-r1'));

      server.sessionWork.tellIntent(
        const OpenTerminalTab(paneId: 'hosted-r1', title: 'run · app'),
      );
      await pumpEventQueue();

      expect(tabsWith(container, 'hosted-r1'), 1);
      final pane = container
          .read(terminalSessionsControllerProvider.notifier)
          .instanceFor('hosted-r1');
      expect(pane, isA<HostTerminalInstance>());
      expect(pane!.title, 'run · app');

      // Asked again, it is the same tab brought forward, not a second.
      server.sessionWork.tellIntent(
        const OpenTerminalTab(paneId: 'hosted-r1', title: 'run · app'),
      );
      await pumpEventQueue();
      expect(tabsWith(container, 'hosted-r1'), 1);
    },
  );

  test('closing a tab the server asked about leaves no tab', () async {
    final (container, server) = await start();
    runOnHost(hostedRunSessionId('hosted-r2'));
    server.sessionWork.tellIntent(
      const OpenTerminalTab(paneId: 'hosted-r2', title: 'shell'),
    );
    await pumpEventQueue();
    expect(tabsWith(container, 'hosted-r2'), 1);

    server.sessionWork.tellIntent(const CloseTerminalTab('hosted-r2'));
    await pumpEventQueue();
    expect(tabsWith(container, 'hosted-r2'), 0);
  });

  test('a session an agent started opens as a tab attached to the '
      'server\'s terminal — nothing is started here', () async {
    final (container, server) = await start();
    final row = session(id: 's9', title: 'Spawned');
    server.sessionRows.insert(row);
    server.sessionWork.running.add('s9');
    runOnHost('karmashala_s9');

    server.sessionWork.tellIntent(
      const OpenSessionTab(sessionId: 's9', title: 'Spawned'),
    );
    await pumpEventQueue();
    await pumpEventQueue();

    final state = container.read(terminalSessionsControllerProvider);
    final panes = [for (final tab in state.tabs) ...tab.layout.panes];
    final agentPanes = [
      for (final id in panes)
        if (container
                .read(terminalSessionsControllerProvider.notifier)
                .instanceFor(id)
                ?.agentLaunch
                ?.sessionId ==
            's9')
          id,
    ];
    expect(agentPanes, hasLength(1));
    expect(
      container.read(sessionsDataProvider).getById('s9')?.paneId,
      agentPanes.single,
    );
    // Asked of the server as a resume, which answered it as running.
    expect(
      server.sessionWork.asked.whereType<SessionStart>(),
      isEmpty,
      reason: 'a session the server runs is never started from here',
    );
  });

  test('closing a session\'s tab the server names by session closes the tab '
      'this window opened under its own pane id', () async {
    final (container, server) = await start();
    server.sessionRows.insert(session(id: 's9', title: 'Spawned'));
    server.sessionWork.running.add('s9');
    runOnHost('karmashala_s9');
    server.sessionWork.tellIntent(
      const OpenSessionTab(sessionId: 's9', title: 'Spawned'),
    );
    await pumpEventQueue();
    await pumpEventQueue();
    final pane = container.read(sessionsDataProvider).getById('s9')!.paneId!;
    expect(pane, isNot('session-s9'));
    expect(tabsWith(container, pane), 1);

    // What terminal_close tells about an agent's terminal it detached.
    server.sessionWork.tellIntent(
      const CloseTerminalTab('session-s9', sessionId: 'karmashala_s9'),
    );
    await pumpEventQueue();
    expect(tabsWith(container, pane), 0);
  });

  test('a session an agent started on an ACP agent opens as its chat tab, '
      'as the New session dialog opens one — never a terminal pane', () async {
    final (container, server) = await start();
    server.installationRows.insert(
      agentInstallation(id: 'acp1', agentId: AgentIds.claudeAcp),
    );
    server.sessionRows.insert(
      session(id: 's10', title: 'ACP child', agentInstallationId: 'acp1'),
    );
    server.sessionWork.running.add('s10');

    server.sessionWork.tellIntent(
      const OpenSessionTab(sessionId: 's10', title: 'ACP child'),
    );
    await pumpEventQueue();
    await pumpEventQueue();

    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final panes = [
      for (final tab in container.read(terminalSessionsControllerProvider).tabs)
        ...tab.layout.panes,
    ];
    expect(panes, contains(chatPaneId('s10')));
    expect(
      [
        for (final id in panes)
          if (controller.instanceFor(id)?.agentLaunch?.sessionId == 's10') id,
      ],
      isEmpty,
      reason: 'the server runs an ACP agent itself; a pane here would be dead',
    );
  });

  group('a session another session started', () {
    /// A parent running in a tab, then a shell the person moved on to: the
    /// parent's tab is not the one in front.
    Future<(ProviderContainer, FakeDataServer, String, String)>
    withParentBehind() async {
      final (container, server) = await start();
      server.sessionRows.insert(session(id: 'p1', title: 'Parent'));
      server.sessionWork.running.add('p1');
      runOnHost('karmashala_p1');
      server.sessionWork.tellIntent(
        const OpenSessionTab(sessionId: 'p1', title: 'Parent'),
      );
      await pumpEventQueue();
      await pumpEventQueue();
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      final parentTab = container
          .read(terminalSessionsControllerProvider)
          .activeTabId!;
      final shellTab = terminals.openTab(TerminalProfile.powerShell);
      container.read(selectedSessionIdProvider.notifier).select('p1');
      return (container, server, parentTab, shellTab);
    }

    void insertChild(
      FakeDataServer server,
      String id, {
      String agentInstallationId = 'a1',
    }) {
      server.sessionRows.insert(
        session(
          id: id,
          title: 'Child',
          agentInstallationId: agentInstallationId,
        ).copyWith(parentSessionId: 'p1'),
      );
      server.sessionWork.running.add(id);
    }

    Future<void> told(FakeDataServer server, Map<String, Object?> json) async {
      server.sessionWork.tellIntent(DataChange.fromJson(json)! as ClientIntent);
      await pumpEventQueue();
      await pumpEventQueue();
    }

    String tabOf(ProviderContainer container, String paneId) => container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((tab) => tab.layout.contains(paneId))
        .id;

    test('opens behind: the tab in front, its pane and the selection stay, '
        'and the new tab sits right after its parent\'s', () async {
      final (container, server, parentTab, shellTab) = await withParentBehind();
      final focusedBefore = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .focusedPaneId;
      insertChild(server, 'c1');
      runOnHost('karmashala_c1');

      await told(server, {
        'change': 'openSessionTab',
        'sessionId': 'c1',
        'title': 'Child',
        'reveal': 'background',
      });

      final state = container.read(terminalSessionsControllerProvider);
      final childTab = tabOf(
        container,
        container.read(sessionsDataProvider).getById('c1')!.paneId!,
      );
      expect(state.activeTabId, shellTab);
      expect(state.activeTab!.focusedPaneId, focusedBefore);
      expect(container.read(selectedSessionIdProvider), 'p1');
      expect(
        [for (final tab in state.tabs) tab.id],
        [parentTab, childTab, shellTab],
      );
      expect(state.unseenTabIds, {childTab});
    });

    test('a chat tab of an ACP child opens behind the same way', () async {
      final (container, server, parentTab, shellTab) = await withParentBehind();
      server.installationRows.insert(
        agentInstallation(id: 'acp1', agentId: AgentIds.claudeAcp),
      );
      insertChild(server, 'c2', agentInstallationId: 'acp1');

      await told(server, {
        'change': 'openSessionTab',
        'sessionId': 'c2',
        'title': 'Child',
        'reveal': 'background',
      });

      final state = container.read(terminalSessionsControllerProvider);
      final chatTab = tabOf(container, chatPaneId('c2'));
      expect(state.activeTabId, shellTab);
      expect(
        [for (final tab in state.tabs) tab.id],
        [parentTab, chatTab, shellTab],
      );
      expect(state.unseenTabIds, {chatTab});
    });

    test(
      'the new mark goes the first time the tab is brought forward',
      () async {
        final (container, server, _, _) = await withParentBehind();
        insertChild(server, 'c3');
        runOnHost('karmashala_c3');
        await told(server, {
          'change': 'openSessionTab',
          'sessionId': 'c3',
          'title': 'Child',
          'reveal': 'background',
        });
        final childTab = container
            .read(terminalSessionsControllerProvider)
            .unseenTabIds
            .single;

        container
            .read(terminalSessionsControllerProvider.notifier)
            .activateTab(childTab);

        final state = container.read(terminalSessionsControllerProvider);
        expect(state.activeTabId, childTab);
        expect(state.unseenTabIds, isEmpty);
      },
    );

    test('from a server that does not say, it comes to the front, as a '
        'person\'s start does', () async {
      final (container, server, _, shellTab) = await withParentBehind();
      insertChild(server, 'c4');
      runOnHost('karmashala_c4');

      await told(server, {
        'change': 'openSessionTab',
        'sessionId': 'c4',
        'title': 'Child',
      });

      final state = container.read(terminalSessionsControllerProvider);
      final childTab = tabOf(
        container,
        container.read(sessionsDataProvider).getById('c4')!.paneId!,
      );
      expect(state.activeTabId, childTab);
      expect(state.activeTabId, isNot(shellTab));
      expect(state.unseenTabIds, isEmpty);
    });

    test('with "bring sessions agents start to the front" on, it comes to '
        'the front as it used to', () async {
      final (container, server, _, _) = await withParentBehind();
      container
          .read(settingsControllerProvider.notifier)
          .setBringAgentSessionsToFront(true);
      insertChild(server, 'c5');
      runOnHost('karmashala_c5');

      await told(server, {
        'change': 'openSessionTab',
        'sessionId': 'c5',
        'title': 'Child',
        'reveal': 'background',
      });

      final state = container.read(terminalSessionsControllerProvider);
      expect(
        state.activeTabId,
        tabOf(
          container,
          container.read(sessionsDataProvider).getById('c5')!.paneId!,
        ),
      );
      expect(state.unseenTabIds, isEmpty);
    });
  });
}
