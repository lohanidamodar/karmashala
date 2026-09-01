import 'dart:async';
import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/lifecycle/app_lifecycle.dart';
import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/command_runner_providers.dart';
import 'package:chitragupta/src/features/agents/data/agent_probe_log.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/mcp/launcher_control_server.dart';
import 'package:chitragupta/src/features/notifications/application/notification_providers.dart';
import 'package:chitragupta/src/features/remote/relay_local/local_relay_providers.dart';
import 'package:chitragupta/src/features/remote/relay_local/local_relay_service.dart';
import 'package:chitragupta/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:chitragupta/src/features/terminal/data/terminal_instance.dart';
import 'package:chitragupta/src/features/terminal/domain/agent_pane_launch.dart';
import 'package:chitragupta/src/features/terminal/domain/terminal_profile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
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
    tmp = Directory.systemTemp.createTempSync('chitra_lifecycle_');
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() {
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
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

  group('ordering', () {
    test('runs outermost first and disposes the container last', () async {
      final order = <String>[];
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      final service = await lifecycle.startSystemIntegration(
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
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
      lifecycle.adopt(
        hookInstallation: Future<void>.error(StateError('hook write failed')),
      );

      await lifecycle.shutdown();

      expect(natives.tray.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
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
      expect(kShutdownBudget, const Duration(milliseconds: 2550));
      expect(
        kShutdownStepBudgets.values.reduce((a, b) => a + b),
        kShutdownBudget,
        reason: 'a shared budget lets the first step starve every later one',
      );
      expect(
        kShutdownStepBudgets['terminal processes'],
        const Duration(milliseconds: 1500),
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
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
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
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
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

      // A literal, and a tight one: the hook step's own 150 ms cap is the whole
      // cost here. Bounding this by `kShutdownBudget` instead meant a step that
      // helped itself to the shared budget still passed.
      expect(
        lifecycle.lastShutdownDuration,
        lessThan(const Duration(milliseconds: 800)),
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
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
      lifecycle.adopt(hookInstallation: Completer<void>().future);
      natives.tray.destroyDelay = const Duration(seconds: 30);

      await lifecycle.shutdown();

      expect(
        lifecycle.lastShutdownDuration,
        lessThan(const Duration(seconds: 2)),
      );
      expect(isDisposed(container), isTrue);
    });

    test('a clean shutdown is far inside Loop 55\'s envelope', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(adapters: natives.adapters);
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
    });
  });

  group('idempotence', () {
    test('a second shutdown is the same shutdown', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(adapters: natives.adapters);

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
}

/// A pane whose process teardown outlives `dispose()`, the way a real one's
/// `taskkill /T` does — with the test holding the future.
class _ReapingInstance extends FakeTerminalInstance
    implements ReapableTerminalInstance {
  _ReapingInstance({
    required super.id,
    required super.title,
    required super.profileId,
    required this.reaped,
  });

  @override
  final Future<void> reaped;
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
