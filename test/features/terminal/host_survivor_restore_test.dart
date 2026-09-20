import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/host_terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/local_host_access.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'fake_instance.dart';

/// A host-backed pane in a background tab comes back running when the host kept
/// its session alive.
///
/// The owner: *"background tabs coming as history if they are still alive —
/// that needs fixing"*. The launch rule leaves background tabs as history so a
/// restore does not re-run what nobody is looking at. A session the host never
/// stopped re-runs nothing, and as history its Start button opened a second
/// shell beside the first, which ran on in the host with no pane.
///
/// Against a **real** host over a real unix socket — only its pty is a fake — so
/// "which sessions are running" is the host's own answer, not a stub's.
void main() {
  late Directory home;
  late HostPaths paths;
  late int starts;

  setUp(() {
    // Short: a unix socket path must fit in 104 bytes on macOS.
    home = Directory.systemTemp.createTempSync('ksr');
    paths = HostPaths(Directory('${home.path}/.k'))..ensureDirectory();
    starts = 0;
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

  ProviderContainer relaunch(AppDatabase db, {bool hostBacked = true}) =>
      ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(database: db),
          hostBackedLocalPanesProvider.overrideWithValue(hostBacked),
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
    AppDatabase db,
  ) {
    final container = fakeTerminalContainer(database: db);
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
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final panes = closeWithThreeTabs(db);
    await hostRunning([hostSessionIdFor(paneId: panes.background)]);

    final next = relaunch(db);
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
    expect(state.livenessOf(panes.foreground), PaneLiveness.live);
    expect(starts, 0);
  });

  test('a host that is not running is not started to ask', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final panes = closeWithThreeTabs(db);
    // No host listening at all.

    final next = relaunch(db);
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

  test('with host-backed panes off, the host is not consulted', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final panes = closeWithThreeTabs(db);
    await hostRunning([hostSessionIdFor(paneId: panes.background)]);

    final next = relaunch(db, hostBacked: false);
    addTearDown(next.dispose);
    next.read(terminalSessionsControllerProvider);
    await next
        .read(terminalSessionsControllerProvider.notifier)
        .hostSurvivorsReattached;

    // Starting it would build a local pty, not attach: the setting decides
    // which process a pane belongs to.
    expect(
      next
          .read(terminalSessionsControllerProvider)
          .livenessOf(panes.background),
      PaneLiveness.restored,
    );
  });
}
