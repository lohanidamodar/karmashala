import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/flutter_apps/application/hosted_run_panes.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_terminal_runtime/instances.dart';

import '../../support/fake_data_server.dart';
import '../terminal/fake_instance.dart';

/// A run the server hosts (slice 3d) opens a pane here, attached to the
/// session the server started — against a real host over a real socket, so
/// the pane finds the session by the id both sides spell the same way.
void main() {
  late Directory home;
  late HostPaths paths;
  late SessionRegistry registry;

  setUp(() async {
    // Short: a unix socket path must fit in 104 bytes on macOS.
    home = Directory.systemTemp.createTempSync('khr');
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

  HostedRun run(String id, {bool ended = false}) => HostedRun(
    runId: id,
    title: 'run · app',
    family: HostedRunFamily.flutter,
    startedAt: DateTime.utc(2026, 9, 27),
    endedAt: ended ? DateTime.utc(2026, 9, 27, 1) : null,
  );

  Future<(ProviderContainer, FakeDataServer)> start() async {
    final server = FakeDataServer();
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
    container.read(hostedRunPanesProvider);
    return (container, server);
  }

  int tabsWith(ProviderContainer container, String paneId) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.contains(paneId)) tab,
  ].length;

  test('a run the server starts opens a pane on its session', () async {
    final (container, server) = await start();
    final started = run('r1');
    registry.open(
      started.hostSessionId,
      const PtySpawnRequest(
        argv: ['sh'],
        environment: {},
        columns: 80,
        rows: 24,
      ),
    );

    server.runs.run(started);
    await pumpEventQueue();

    expect(tabsWith(container, 'hosted-r1'), 1);
    final pane = container
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor('hosted-r1');
    expect(pane, isA<HostTerminalInstance>());
    expect(pane!.title, 'run · app');

    // Told again (its end), it is the same pane, not a second.
    server.runs.run(run('r1', ended: true));
    await pumpEventQueue();
    expect(tabsWith(container, 'hosted-r1'), 1);
  });

  test('a run that had already ended when told opens nothing', () async {
    final (container, server) = await start();
    server.runs.run(run('r2', ended: true));
    await pumpEventQueue();
    expect(tabsWith(container, 'hosted-r2'), 0);
  });
}
