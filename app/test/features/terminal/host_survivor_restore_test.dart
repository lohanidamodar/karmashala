import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show TerminalRecord, terminalSessionId;

import '../../support/fake_data_server.dart';
import 'fake_instance.dart';

/// A pane in a background tab comes back running when the server kept its
/// terminal alive (slice 5a: the server owns every local terminal).
///
/// The owner: *"background tabs coming as history if they are still alive —
/// that needs fixing"*. The launch rule leaves background tabs as history so a
/// restore does not re-run what nobody is looking at. A session the host never
/// stopped re-runs nothing, and as history its Start button opened a second
/// shell beside the first, which ran on in the host with no pane.
///
/// Which terminals run is the server's answer (`terminals.list`, the fake data
/// server here); the pane then attaches, attach-only, over a **real** host on a
/// real unix socket — only its pty is a fake.
void main() {
  late Directory home;
  late HostPaths paths;
  late int starts;
  late FakeDataServer data;

  setUp(() {
    // Short: a unix socket path must fit in 104 bytes on macOS.
    home = Directory.systemTemp.createTempSync('ksr');
    paths = HostPaths(Directory('${home.path}/.k'))..ensureDirectory();
    starts = 0;
    data = FakeDataServer();
  });
  tearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // A socket node can still be held on Windows.
    }
  });

  /// A host listening on [paths], holding a running session for each id.
  Future<void> hostRunning(List<String> sessionIds) async {
    final registry = SessionRegistry(launcher: FakePtyLauncher());
    final server = HostServer(registry: registry, ptyLibrary: 'fake');
    final listener = await UnixSocketHostListener.bind(paths.socketPath);
    final subscription = server.listen(listener);
    addTearDown(() async {
      await subscription.cancel();
      await listener.close();
      await registry.shutdown();
    });
    for (final id in sessionIds) {
      data.terminals.records[id] = TerminalRecord(
        sessionId: id,
        paneId: '',
        profileId: 'powershell',
        title: 'sh',
        startedAt: DateTime.utc(2026),
      );
      registry.open(
        id,
        const PtySpawnRequest(
          argv: ['sh'],
          environment: {},
          columns: 80,
          rows: 24,
        ),
      );
    }
  }

  Future<ProviderContainer> relaunch(TerminalLayoutStore db) async =>
      ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(
            layoutStore: db,
            data: await data.override(),
          ),
          localHostSessionAccessProvider.overrideWithValue(
            LocalHostSessionAccess(
              paths: paths,
              executable: LocalHostExecutable(executableDirectory: home.path),
              // Asking what survived must never start a host.
              startServe: (_) async {
                starts++;
                throw StateError('a host was started to ask what survived');
              },
            ),
          ),
        ],
      );

  /// Opens three tabs and quits: [background] and [unhosted] behind the active
  /// [foreground]. Returns their pane ids.
  ({String background, String unhosted, String foreground}) closeWithThreeTabs(
    TerminalLayoutStore db,
  ) {
    final container = fakeTerminalContainer(layoutStore: db);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    String paneOf(String tabId) => container
        .read(terminalSessionsControllerProvider)
        .tabs
        .firstWhere((t) => t.id == tabId)
        .layout
        .panes
        .single;
    final background = paneOf(controller.openTab(TerminalProfile.powerShell));
    final unhosted = paneOf(controller.openTab(TerminalProfile.powerShell));
    final foreground = paneOf(
      controller.openTab(TerminalProfile.commandPrompt),
    );
    controller.persistLayout();
    container.dispose();
    return (background: background, unhosted: unhosted, foreground: foreground);
  }

  test('a background pane the host kept running comes back running', () async {
    final db = TerminalLayoutStore.memory();
    addTearDown(db.close);
    final panes = closeWithThreeTabs(db);
    await hostRunning([terminalSessionId(paneId: panes.background)]);

    final next = await relaunch(db);
    addTearDown(next.dispose);
    // Restored first, synchronously, exactly as before: the host is asked after.
    expect(
      next
          .read(terminalSessionsControllerProvider)
          .livenessOf(panes.background),
      PaneLiveness.restored,
    );
    await next
        .read(terminalSessionsControllerProvider.notifier)
        .hostSurvivorsReattached;

    final state = next.read(terminalSessionsControllerProvider);
    expect(
      state.livenessOf(panes.background),
      PaneLiveness.live,
      reason: 'its session never stopped, so it is not history',
    );
    // A background pane with nothing running in the host keeps its Start:
    // reattaching is the exception, not a second way to restart everything.
    expect(state.livenessOf(panes.unhosted), PaneLiveness.restored);
    // The front pane was re-attached too (the launch rule), and its terminal
    // is gone: it ends, and its Start is what asks the server for a new one —
    // a restore never starts anything by itself.
    await pumpEventQueue();
    expect(state.livenessOf(panes.foreground), isNot(PaneLiveness.live));
    expect(starts, 0);
  });

  test('a host that is not running is not started to ask', () async {
    final db = TerminalLayoutStore.memory();
    addTearDown(db.close);
    final panes = closeWithThreeTabs(db);
    // No host listening at all.

    final next = await relaunch(db);
    addTearDown(next.dispose);
    next.read(terminalSessionsControllerProvider);
    await next
        .read(terminalSessionsControllerProvider.notifier)
        .hostSurvivorsReattached;

    expect(
      next
          .read(terminalSessionsControllerProvider)
          .livenessOf(panes.background),
      PaneLiveness.restored,
    );
    expect(starts, 0, reason: 'nothing survives in a host that is not running');
  });

  test('a terminal the server says has ended is left as history', () async {
    final db = TerminalLayoutStore.memory();
    addTearDown(db.close);
    final panes = closeWithThreeTabs(db);
    final id = terminalSessionId(paneId: panes.background);
    await hostRunning([id]);
    data.terminals.records[id] = data.terminals.records[id]!.copyWith(
      endedAt: DateTime.utc(2026, 1, 2),
      exitCode: 0,
    );

    final next = await relaunch(db);
    addTearDown(next.dispose);
    next.read(terminalSessionsControllerProvider);
    await next
        .read(terminalSessionsControllerProvider.notifier)
        .hostSurvivorsReattached;

    // Its Start asks the server for a new one; nothing restarts on its own.
    expect(
      next
          .read(terminalSessionsControllerProvider)
          .livenessOf(panes.background),
      PaneLiveness.restored,
    );
  });
}
