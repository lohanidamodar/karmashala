import 'dart:io';

import 'package:agent_cli/descriptors.dart' show AgentIds;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/client_intents.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
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
}
