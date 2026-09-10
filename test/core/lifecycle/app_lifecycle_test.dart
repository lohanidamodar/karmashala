import 'dart:async';
import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/agents/data/agent_probe_log.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:karmashala/src/features/remote/relay_local/local_relay_service.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/process_shutdown.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import '../../features/system/fake_native_adapters.dart';
import '../../features/terminal/fake_instance.dart';

/// The application lifecycle owner.
///
/// The 2026-08-30 audit found that nothing in the app owned shutdown:
/// `SystemIntegrationService` was a temporary expression, `LauncherControlServer`
/// sat in a local whose comment claimed otherwise, and `stop()` — which deletes
/// the bridge handshake — had no caller at all. A normal quit therefore left a
/// handshake on disk advertising a port nothing was listening on.
/// Whether [container] has been disposed.
///
/// Riverpod 3.3 does not expose a `disposed` getter, and reading through a
/// disposed container is exactly what the lifecycle owner must have made
/// impossible, so the observable behaviour is the assertion.
bool isDisposed(ProviderContainer container) {
  try {
    container.read(agentStatusWatcherProvider);
    return false;
  } on StateError {
    return true;
  }
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_lifecycle_');
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() {
    db.close();
    // **One call, not exists-then-delete.** The guard was a TOCTOU: a case
    // that had already failed may have taken its directory with it between
    // the two lines, and the `PathNotFoundException` that followed buried the
    // assertion that actually failed under a teardown error.
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Already gone, or something inside it went while this walked.
    }
  });

  group('the control server it owns', () {
    test('graceful shutdown deletes the handshake', () async {
      final lifecycle = AppLifecycle(container);
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      // `startControlServer` starts its own; this test owns the paths, so it
      // hands over an already-started instance the same way the app hands over
      // a freshly built one.
      lifecycle.adopt(controlServer: server);
      expect(File(bridge).existsSync(), isTrue);

      await lifecycle.shutdown();

      expect(
        File(bridge).existsSync(),
        isFalse,
        reason: 'a stale handshake points a bridge at a dead port',
      );
      expect(File(p.join(tmp.path, 'ipc', 'rpc.sock')).existsSync(), isFalse);
    });

    test('it is retained before it is started, not after', () async {
      // **What the app soak found.** `start()` publishes the handshake
      // part-way through — the socket node is already bound, the WSL listener
      // and the session configs are still to come — and this field used to be
      // assigned only once `start()` returned. So from the moment
      // `mcp_bridge.json` appeared there were several hundred milliseconds in
      // which a quit found step 3 with nothing to stop, and it said nothing
      // about it: no skip, no timeout, no failure. 18 of 20 quits left the
      // handshake, the socket node and `data\mcp` behind that way.
      final lifecycle = AppLifecycle(container);
      final server = LauncherControlServer(container);

      final starting = lifecycle.startControlServer(server: server);

      expect(
        lifecycle.controlServer,
        same(server),
        reason: 'a quit that lands mid-start must find something to stop',
      );
      await starting;
      await server.stop();
    });

    test('a stop that lands mid-start leaves nothing published', () async {
      // The other half. Retaining the instance is no use if the rest of the
      // start then publishes over what `stop()` has just removed — and it did:
      // the handshake is *written* several awaits after the empty file that
      // carries its ACL is created, so a stop in between removed a file the
      // start then put back, in full, on its way out.
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      final sessionConfigs = Directory(p.join(tmp.path, 'mcp'));
      // The ACL call is the synchronisation point rather than a delay: it sits
      // exactly where the soak's close message arrived, with the socket node
      // already bound and the handshake not yet written.
      final atRestrict = Completer<void>();
      final release = Completer<bool>();
      final server = LauncherControlServer(
        container,
        permissions: _GatedPermissions(atRestrict, release),
      );

      final starting = server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
        sessionConfigDirectory: sessionConfigs.path,
      );
      await atRestrict.future;

      await server.stop();
      release.complete(true);
      await starting;

      expect(
        File(bridge).existsSync(),
        isFalse,
        reason: 'the rest of the start published on its way out',
      );
      expect(File(p.join(tmp.path, 'ipc', 'rpc.sock')).existsSync(), isFalse);
      expect(sessionConfigs.existsSync(), isFalse);
    });

    test('the pid stays in the handshake for the crash case', () async {
      // Graceful quit removes the file; a crash cannot, which is why the pid it
      // publishes has to stay there for a reader to validate.
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      addTearDown(server.stop);

      expect(File(bridge).readAsStringSync(), contains('"pid":$pid'));
    });
  });

  group('the database it closes', () {
    test('a graceful quit closes the handle, not just the process', () async {
      // `exit(0)` releases the file and gives SQLite no chance to checkpoint,
      // so all 20 of the soak's cycles left `karmashala.sqlite-wal` and `-shm`
      // for the next launch to recover from. A `close()` writes them back and
      // removes them.
      final lifecycle = AppLifecycle(container);

      await lifecycle.shutdown();

      expect(
        () => db.readMetadata(MetadataKeys.firstRunAt),
        throwsA(anything),
        reason: 'the handle outlived the shutdown that owns it',
      );
    });
  });

  group('ordering', () {
    test('runs outermost first and disposes the container last', () async {
      final order = <String>[];
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      final service = await lifecycle.startSystemIntegration(
        endProcess: () {},
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );
      // Force the watcher to exist so the step has something to do.
      container.read(agentStatusWatcherProvider);
      lifecycle.adopt(
        controlServer: _RecordingControlServer(container, order),
        hookInstallation: Future<void>(() => order.add('hooks')),
      );
      natives.tray.onDestroy = () => order.add('system integration');

      await lifecycle.shutdown();

      expect(order, ['hooks', 'control server', 'system integration']);
      expect(isDisposed(container), isTrue);
      // And the service really is detached, not merely marked so.
      expect(natives.window.listeners, isEmpty);
      expect(natives.tray.listeners, isEmpty);
      expect(service, isNotNull);
    });

    test('a step that throws does not stop the ones after it', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(
endProcess: () {},
registerOsQuit: (_) {}, adapters: natives.adapters);
      lifecycle.adopt(
        hookInstallation: Future<void>.error(StateError('hook write failed')),
      );

      await lifecycle.shutdown();

      expect(natives.tray.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });
  });

  group('nothing it started outlives it', () {
    /// **The bug this group exists for, and the shape of it.**
    ///
    /// `_step` bounds the **wait**, not the work — a Dart future cannot be
    /// cancelled — and the control server's slice is 100 ms. The handshake
    /// delete used to sit *last* in `LauncherControlServer.stop`, behind three
    /// awaited socket closes, so on a loaded machine `shutdown()` returned with
    /// `mcp_bridge.json` still on disk and the deletes landed afterwards at a
    /// moment nothing owned. Two symptoms, one event: the assertion this owner
    /// exists for was false, and the stray deletes raced the suite's own
    /// `deleteSync(recursive: true)` into a `PathNotFoundException` — a
    /// different pair of tests each run, because which steps blow their slice
    /// depends on the load.
    ///
    /// Both cases below are **counted, never timed**: the first observes the
    /// files without awaiting anything, the second compares a removal count
    /// across a pumped event queue.

    test('the published files are gone before stop() suspends', () async {
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      final socket = p.join(tmp.path, 'ipc', 'rpc.sock');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      expect(File(bridge).existsSync(), isTrue);

      // Deliberately not awaited. Everything between this line and the next is
      // `stop`'s synchronous prefix, which is the only part of it a bounded
      // step cannot be preempted out of.
      final pending = server.stop();

      expect(
        File(bridge).existsSync(),
        isFalse,
        reason: 'the handshake outlived the first await',
      );
      expect(
        File(socket).existsSync(),
        isFalse,
        reason: 'the socket node outlived the first await',
      );

      await pending;
    });

    test('a shutdown that abandons the step still leaves nothing behind', () async {
      final removals = <String>[];
      final lifecycle = AppLifecycle(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      final server = LauncherControlServer(
        container,
        unpublish: (path) {
          removals.add(path);
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        },
      );
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      // A hook step that never returns, so the budget is already under
      // pressure when the control server's turn comes — the shape of the run
      // that failed.
      lifecycle.adopt(
        controlServer: server,
        hookInstallation: Completer<void>().future,
      );

      await lifecycle.shutdown();

      final counted = removals.length;
      expect(counted, 2, reason: 'the handshake and the socket node');
      expect(File(bridge).existsSync(), isFalse);

      // **The count, not the clock.** Every continuation the abandoned step
      // left behind runs here; if any of them still removed something, this
      // grows. A `pumpEventQueue` drains the microtask and event queues rather
      // than waiting out a duration, so a slower machine cannot pass it by
      // being slow.
      await pumpEventQueue();
      await pumpEventQueue();

      expect(
        removals.length,
        counted,
        reason: 'a filesystem removal outlived shutdown()',
      );
    });
  });

  group('the panes it reaps', () {
    /// A container whose panes are fakes with a reap the test controls.
    (ProviderContainer, List<_ReapingInstance>) reapingContainer(
      Future<void> reaped,
    ) {
      final built = <_ReapingInstance>[];
      final container = ProviderContainer(
        overrides: fakeTerminalOverrides(
          database: db,
          instanceFactory:
              ({
                required String id,
                required TerminalProfile profile,
                String? workingDirectory,
                String? restoredScrollback,
                bool shellIntegration = false,
                AgentPaneLaunch? agentLaunch,
                Terminal? adoptTerminal,
              }) {
                final instance = _ReapingInstance(
                  id: id,
                  title: profile.label,
                  profileId: profile.id,
                  reaped: reaped,
                );
                built.add(instance);
                return instance;
              },
        ),
      );
      return (container, built);
    }

    test('shutdown waits for the kill, then closes', () async {
      // A2: `dispose()` fired the `taskkill /T` and dropped the future, so
      // `windowManager.destroy()` raced it. With a live pane the sequence must
      // not finish while the kill is still in flight.
      final killed = Completer<void>();
      final (container, panes) = reapingContainer(killed.future);
      final lifecycle = AppLifecycle(container);
      container
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(TerminalProfile.powerShell);

      var finished = false;
      final shutdown = lifecycle.shutdown().whenComplete(() => finished = true);
      await pumpEventQueue();

      expect(panes.single.disposed, isTrue, reason: 'the kill was started');
      expect(
        finished,
        isFalse,
        reason: 'the app must not close while a child process is still dying',
      );
      expect(isDisposed(container), isFalse);

      killed.complete();
      await shutdown;

      expect(finished, isTrue);
      expect(isDisposed(container), isTrue);
      // The whole sequence, with a pane in it, inside Loop 55's envelope.
      expect(
        lifecycle.lastShutdownDuration,
        lessThan(const Duration(milliseconds: 500)),
      );
    });

    test('a pane keeps its pseudoconsole when the process is ending', () async {
      // The second of the two cycles in twenty that ignored `WM_CLOSE`, and the
      // only one of the findings that no Dart bound could have covered:
      // releasing a pseudoconsole is a synchronous Windows call, and a
      // synchronous call that does not return takes the isolate's timers with
      // it. See [PseudoConsoleOwner].
      final (container, panes) = reapingContainer(Future<void>.value());
      final lifecycle = AppLifecycle(container);
      container
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(TerminalProfile.powerShell);

      await lifecycle.shutdown();

      expect(panes.single.keptPseudoConsole, isTrue);
      expect(
        panes.single.keptWhileUndisposed,
        isTrue,
        reason: 'dispose builds the chain that releases it; too late after',
      );
    });

    test('a pane closed in a running app still releases it', () async {
      // The other half, and the reason this is per pane rather than a flag on
      // the process: a long session that never released a console would strand
      // a descriptor and a reader thread per closed pane, which is the leak
      // 2026-09-03 measured and fixed.
      final (container, panes) = reapingContainer(Future<void>.value());
      addTearDown(container.dispose);
      final terminals = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      terminals.openTab(TerminalProfile.powerShell);
      terminals.openTab(TerminalProfile.powerShell);

      terminals.closeTab(container.read(terminalSessionsControllerProvider).tabs.first.id);

      expect(panes.first.disposed, isTrue, reason: 'the pane was closed');
      expect(panes.first.keptPseudoConsole, isFalse);
    });

    test('a kill that never lands does not hold the app open', () async {
      final (container, panes) = reapingContainer(Completer<void>().future);
      // Injected: the property is that the step is abandoned, and proving it
      // against the shipped 1.5 s cap would cost 1.5 s of wall clock per run.
      final lifecycle = AppLifecycle(
        container,
        shutdownBudget: const Duration(milliseconds: 60),
      );
      container
          .read(terminalSessionsControllerProvider.notifier)
          .openTab(TerminalProfile.powerShell);

      await lifecycle.shutdown();

      expect(panes.single.disposed, isTrue);
      expect(
        isDisposed(container),
        isTrue,
        reason: 'the container goes even when the budget is spent',
      );
    });
  });

  group('the local relay it stops', () {
    test(
      'shutdown closes a running embedded relay and frees its port',
      () async {
        // Loopback and an empty interface list: nothing leaves this machine.
        final relay = LocalRelayService(
          bindAddress: '127.0.0.1',
          interfaces: () async => [],
        );
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            localRelayServiceProvider.overrideWithValue(relay),
          ],
        );
        final lifecycle = AppLifecycle(container);
        await container.read(localRelayServiceProvider).ensureRunning(0);
        final port = relay.status.boundPort!;

        await lifecycle.shutdown();

        expect(relay.status.state, LocalRelayState.stopped);
        final rebound = await ServerSocket.bind('127.0.0.1', port);
        await rebound.close();
      },
    );
  });

  group('the budget', () {
    test('is the itemised sum of the steps, and both are pinned', () {
      // Pinned to literals on purpose. The two bounds this replaces were
      // written against `kShutdownBudget` itself, so widening the constant —
      // the exact regression they existed to catch — kept them green.
      expect(kShutdownBudget, const Duration(milliseconds: 3550));
      expect(
        kShutdownStepBudgets.values.reduce((a, b) => a + b),
        kShutdownBudget,
        reason: 'a shared budget lets the first step starve every later one',
      );
      expect(
        kShutdownStepBudgets['terminal processes'],
        const Duration(milliseconds: 2500),
        reason: '1500 was under the measured cost of one taskkill.exe',
      );
      expect(
        kShutdownStepBudgets['terminal processes'],
        kProcessTreeKillBound,
        reason: 'a kill still being waited on after its step was abandoned is '
            'work outliving the shutdown that owns it',
      );
      expect(kShutdownStepBudgets, hasLength(9));
    });

    test('a spent budget skips every step but still disposes', () async {
      // The accounting, on a clock the test owns: no real milliseconds pass,
      // and the answer does not depend on how busy the machine is.
      final lifecycle = AppLifecycle(
        container,
        stopwatch: _FrozenStopwatch(const Duration(seconds: 5)),
      );
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(
endProcess: () {},
registerOsQuit: (_) {}, adapters: natives.adapters);
      lifecycle.adopt(hookInstallation: Completer<void>().future);

      await lifecycle.shutdown();

      expect(
        natives.tray.destroyed,
        isFalse,
        reason: 'every step is skipped once the budget is gone',
      );
      expect(
        isDisposed(container),
        isTrue,
        reason: 'the container is disposed regardless — nothing else can',
      );
      expect(lifecycle.lastShutdownDuration, const Duration(seconds: 5));
    });

    test('a step that hangs does not starve the ones after it', () async {
      // The first draft shared one budget across the sequence, so a hook
      // rewrite that never returned spent all of it and the control server —
      // the step that deletes the handshake — was skipped entirely. That is the
      // exact failure this owner exists to prevent, so it gets its own test.
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(
endProcess: () {},
registerOsQuit: (_) {}, adapters: natives.adapters);
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      // A hook rewrite that never returns — the shape of Loop 48's build that
      // could not exit at all.
      lifecycle.adopt(
        controlServer: server,
        hookInstallation: Completer<void>().future,
      );

      await lifecycle.shutdown();

      // **Counted, not timed.** This used to be `lastShutdownDuration <
      // 800 ms`, and under six concurrent suites it read 902 ms — which said
      // nothing about the budget and everything about the machine. Worse, it
      // was weak in the direction that matters: a 700 ms shutdown that skipped
      // the control server step entirely would have passed it. The property is
      // that *this* step was cut off at its own cap and nothing after it was
      // starved, and that is two lists.
      expect(
        lifecycle.abandonedSteps,
        ['agent hook installation'],
        reason: 'only the step that hangs may be cut off',
      );
      expect(
        lifecycle.skippedSteps,
        isEmpty,
        reason: 'a hanging step helped itself to the shared budget',
      );
      expect(File(bridge).existsSync(), isFalse, reason: 'handshake removed');
      expect(natives.tray.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });

    test('every step hanging still finishes inside the deadline', () async {
      // 60 ms rather than the shipped 2.2 s: the property is that the deadline
      // is enforced, and waiting out the real one is 2.2 s of wall clock per
      // run for the same answer.
      final lifecycle = AppLifecycle(
        container,
        shutdownBudget: const Duration(milliseconds: 60),
      );
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(
endProcess: () {},
registerOsQuit: (_) {}, adapters: natives.adapters);
      lifecycle.adopt(hookInstallation: Completer<void>().future);
      natives.tray.destroyDelay = const Duration(seconds: 30);

      await lifecycle.shutdown();

      // **Counted.** That `shutdown()` returned at all is what proves the
      // deadline was enforced — a sequence that waited on the 30 s tray would
      // have hung this case, not made it slow. What the number used to stand
      // in for is here instead: the hanging step was cut off at the budget,
      // the ones behind it were skipped rather than waited on, and the
      // container was disposed anyway.
      expect(lifecycle.abandonedSteps, ['agent hook installation']);
      expect(
        lifecycle.skippedSteps,
        isNotEmpty,
        reason: 'a spent budget must skip the rest, not wait on them',
      );
      expect(isDisposed(container), isTrue);
    });

    test('a clean shutdown is far inside Loop 55\'s envelope', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(
endProcess: () {},
registerOsQuit: (_) {}, adapters: natives.adapters);
      final server = LauncherControlServer(container);
      await server.start(
        bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      lifecycle.adopt(controlServer: server);

      await lifecycle.shutdown();

      // The literal is Loop 55's measured envelope (225–396 ms end to end), not
      // the constant: a shutdown that got slower would still be "inside the
      // budget" the moment someone widened the budget.
      expect(
        lifecycle.lastShutdownDuration,
        lessThan(const Duration(milliseconds: 500)),
      );
    },
        // **The one case here that is a wall-clock measurement, and it is
        // opt-in for that reason.** Every bound in `AppLifecycle` is a real
        // timeout, so a starved scheduler overshoots all of them at once: with
        // six suites running this read 3.03 s and said nothing about the app.
        // Every other case in this file was rewritten to count what ran; this
        // one cannot be, because the number *is* the claim. So it runs
        // deliberately, on a quiet machine, and skips itself with its reason
        // the way §18's live tests do:
        //
        //     KARMASHALA_TIMING=1 flutter test test/core/lifecycle
        tags: 'live-timing',
        skip: Platform.environment['KARMASHALA_TIMING'] == null
            ? 'a wall-clock envelope, and this gate runs beside other gates. '
                  'Set KARMASHALA_TIMING=1 on a quiet machine to measure it.'
            : false);
  });

  group('idempotence', () {
    test('a second shutdown is the same shutdown', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(
endProcess: () {},
registerOsQuit: (_) {}, adapters: natives.adapters);

      await Future.wait([lifecycle.shutdown(), lifecycle.shutdown()]);
      await lifecycle.shutdown();

      expect(
        natives.tray.calls.where((c) => c == 'destroy'),
        hasLength(1),
        reason: 'the sequence runs once however many exits call it',
      );
      expect(lifecycle.isShuttingDown, isTrue);
    });

    test('quitting from the tray runs the whole sequence', () async {
      // The wiring the audit asked for: the graceful quit path goes through
      // this owner *before* the window is destroyed.
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      final service = await lifecycle.startSystemIntegration(
        endProcess: () {},
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      lifecycle.adopt(controlServer: server);

      await service.quit();

      expect(File(bridge).existsSync(), isFalse);
      expect(natives.window.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });

    test('closing the window runs the whole sequence too', () async {
      // The X is the default way out, and it used to run none of this:
      // prevent-close was derived from close-to-tray (off by default), so
      // `WM_CLOSE` fell through to `DefWindowProc` and destroyed the window
      // before the `close` event reached Dart. The first expectation below is
      // the whole fix; the rest is what it buys.
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      final service = await lifecycle.startSystemIntegration(
        endProcess: () {},
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );
      final server = LauncherControlServer(container);
      final bridge = p.join(tmp.path, 'mcp_bridge.json');
      await server.start(
        bridgeFilePath: bridge,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
      lifecycle.adopt(controlServer: server);

      expect(
        natives.window.preventClose,
        isTrue,
        reason: 'without this the window is gone before onWindowClose runs',
      );

      service.onWindowClose();
      // The same sequence, awaited: `shutdown` is idempotent, so this is the
      // future the window's close path started, not a second one.
      await lifecycle.shutdown();
      await pumpEventQueue();

      expect(File(bridge).existsSync(), isFalse);
      expect(natives.window.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });
  });

  group('agents nobody has ever looked for', () {
    test('a workspace that has discovered before sweeps for new agents', () async {
      db.writeMetadata(MetadataKeys.agentsDiscoveredAt, '2026-07-28T00:00:00Z');
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      final runner = FakeCommandRunner(
        responder: (req) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: '',
        ),
      );
      final scoped = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        ],
      );
      addTearDown(scoped.dispose);

      AppLifecycle(scoped).startAgentDiscovery();
      await pumpEventQueue();

      // Every shipped agent, asked about once, because this workspace has no
      // record of ever having looked.
      expect(runner.requests, isNotEmpty);
      expect(AgentProbeLog(db).hasProbed(AgentIds.antigravity, 'windows'), isTrue);
    });

    test('a workspace that has never discovered leaves it to the first run', () async {
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      final runner = FakeCommandRunner();
      final scoped = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        ],
      );
      addTearDown(scoped.dispose);

      AppLifecycle(scoped).startAgentDiscovery();
      await pumpEventQueue();

      // The one-time startup scan is already probing everything; two sweeps
      // racing would spawn every probe twice.
      expect(runner.requests, isEmpty);
    });
  });

  group('the agents\' hooks are installed behind the first frame', () {
    /// A server with a hook endpoint and no bound port. `hookEndpoint` is the
    /// only thing `installAgentHooks` reads, and binding one here would buy
    /// nothing but a socket.
    _HookOnlyServer serverFor(ProviderContainer container) =>
        _HookOnlyServer(container);

    test('the sweep does not start until the gate is released', () async {
      final sweeps = <int>[];
      final scoped = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          agentHookInstallationServiceProvider.overrideWith(
            (ref) => _RecordingHookService(ref, sweeps),
          ),
        ],
      );
      addTearDown(scoped.dispose);
      final lifecycle = AppLifecycle(scoped);
      final gate = Completer<void>();

      lifecycle.installAgentHooks(
        serverFor(scoped),
        afterFirstFrame: () => gate.future,
      );
      await pumpEventQueue();

      // This is the whole point: the sweep rewrites three other applications'
      // global config files across up to four filesystems, and until Loop 78 it
      // did that in the same isolate turn the window was trying to paint in —
      // 1053 ms of a 1.91 s launch on the owner's machine.
      expect(sweeps, isEmpty, reason: 'the window has not painted yet');
      // And the app says so rather than saying nothing. An empty report used
      // to be indistinguishable from a clean one.
      expect(
        scoped.read(agentHookInstallationReportProvider).swept,
        isFalse,
      );

      gate.complete();
      await pumpEventQueue();

      expect(sweeps, [1]);
      expect(scoped.read(agentHookInstallationReportProvider).swept, isTrue);
    });

    test('a gate that throws still gets the hooks installed', () async {
      // The gate is about *when*, never about *whether*: a launch whose first
      // frame never comes — minimised to the tray — must not be a launch with
      // no status callbacks at all.
      final sweeps = <int>[];
      final scoped = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          agentHookInstallationServiceProvider.overrideWith(
            (ref) => _RecordingHookService(ref, sweeps),
          ),
        ],
      );
      addTearDown(scoped.dispose);

      AppLifecycle(scoped).installAgentHooks(
        serverFor(scoped),
        afterFirstFrame: () => Future<void>.error(StateError('no binding')),
      );
      await pumpEventQueue();

      expect(sweeps, [1]);
    });

    test('the WSL re-sweep waits for nothing', () async {
      // By the time the switch binds the window has long since painted, so a
      // re-sweep that waited for a *further* frame would be waiting on an idle
      // app. The gate is only ever the first sweep's.
      final sweeps = <int>[];
      final scoped = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          agentHookInstallationServiceProvider.overrideWith(
            (ref) => _RecordingHookService(ref, sweeps),
          ),
        ],
      );
      addTearDown(scoped.dispose);
      final server = serverFor(scoped);
      final gate = Completer<void>();

      AppLifecycle(scoped).installAgentHooks(
        server,
        afterFirstFrame: () => gate.future,
      );
      server.onWslInterfaceBound!();
      await pumpEventQueue();

      expect(sweeps, [1], reason: 'the first sweep is still behind the gate');
    });
  });
}

/// A pane whose process teardown outlives `dispose()`, the way a real one's
/// `taskkill /T` does — with the test holding the future.
class _ReapingInstance extends FakeTerminalInstance
    implements ReapableTerminalInstance, PseudoConsoleOwner {
  _ReapingInstance({
    required super.id,
    required super.title,
    required super.profileId,
    required this.reaped,
  });

  @override
  final Future<void> reaped;

  /// Whether the quit told this pane to leave its console to the OS, and
  /// whether it did so while the pane was still there to be told. Recorded
  /// rather than counted at the end, because "before `dispose`" is the whole
  /// property: after it the chain that releases the console is already built.
  bool keptPseudoConsole = false;
  bool keptWhileUndisposed = false;

  @override
  void keepPseudoConsoleOnDispose() {
    keptPseudoConsole = true;
    keptWhileUndisposed = !disposed;
  }
}

/// A [Stopwatch] that always reports the same elapsed time, so the shutdown
/// budget can be spent (or not) without a single real millisecond passing.
class _FrozenStopwatch implements Stopwatch {
  _FrozenStopwatch(this.elapsed);

  @override
  final Duration elapsed;

  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
  @override
  int get elapsedTicks => elapsed.inMicroseconds;
  @override
  int get frequency => Duration.microsecondsPerSecond;
  @override
  bool get isRunning => true;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  void reset() {}
}

/// A server that has a hook endpoint and nothing else. Binding a port would
/// buy this test nothing: `installAgentHooks` reads `hookEndpoint` and sets
/// `onWslInterfaceBound`, and neither needs a socket.
class _HookOnlyServer extends LauncherControlServer {
  _HookOnlyServer(super.container);

  @override
  AgentHookEndpoint? get hookEndpoint =>
      const AgentHookEndpoint(port: 4242, token: 'tok');
}

/// Counts sweeps and touches no config file. The real service walks every
/// located CLI store, which on this machine means the developer's own
/// `~/.claude` — never something a unit test may write into.
class _RecordingHookService extends AgentHookInstallationService {
  _RecordingHookService(super.ref, this._sweeps);

  final List<int> _sweeps;

  @override
  Future<List<AgentHookInstallation>> installAll(AgentHookEndpoint endpoint) {
    _sweeps.add(_sweeps.length + 1);
    return Future.value(const <AgentHookInstallation>[]);
  }
}

/// A control server that records when it was stopped, without binding a port.
class _RecordingControlServer extends LauncherControlServer {
  _RecordingControlServer(super.container, this._order);

  final List<String> _order;

  @override
  Future<void> stop() async {
    _order.add('control server');
    await super.stop();
  }
}

/// Suspends the handshake file's ACL call, which is where a quit lands: the
/// socket node is bound, `mcp_bridge.json` exists and is still empty, and the
/// tokens have not been written into it yet.
class _GatedPermissions extends HandshakePermissions {
  _GatedPermissions(this._reached, this._release);

  final Completer<void> _reached;
  final Completer<bool> _release;

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) {
    if (!_reached.isCompleted) _reached.complete();
    return _release.future;
  }

  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      true;
}
