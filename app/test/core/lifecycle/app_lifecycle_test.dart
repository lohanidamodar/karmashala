import 'dart:async';
import 'dart:io';

import 'package:karmashala/src/features/terminal/application/terminal_layout_providers.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala/src/core/lifecycle/app_lifecycle.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/terminal/application/local_host_startup.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/agents/application/host_hook_endpoint.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_ssh_host/host.dart' show HostDeployment;
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

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
    container.read(attentionPresenterProvider);
    return false;
  } on StateError {
    return true;
  }
}

void main() {
  late Directory tmp;
  late TerminalLayoutStore layout;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('karmashala_lifecycle_');
    layout = TerminalLayoutStore.memory();
    container = ProviderContainer(
      overrides: [terminalLayoutStoreProvider.overrideWithValue(layout)],
    );
  });

  tearDown(() {
    try {
      layout.close();
    } on Object {
      // The shutdown under test closed it already.
    }
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


  group('the database it closes', () {
    test('a graceful quit closes the handle, not just the process', () async {
      // `exit(0)` releases the file and gives SQLite no chance to checkpoint,
      // so all 20 of the soak's cycles left a `-wal` and `-shm` for the next
      // launch to recover from. A `close()` writes them back and removes
      // them. The app's one database is its own terminal layout, open once
      // the terminals have read it.
      container.read(terminalLayoutStoreProvider);
      final lifecycle = AppLifecycle(container);

      await lifecycle.shutdown();

      expect(
        () => layout.query('SELECT 1;'),
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
      container.read(attentionPresenterProvider);
      lifecycle.adopt(
        hookInstallation: Future<void>(() => order.add('hooks')),
      );
      natives.tray.onDestroy = () => order.add('system integration');

      await lifecycle.shutdown();

      expect(order, ['hooks', 'system integration']);
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
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );
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

  group('the budget', () {
    test('is the itemised sum of the steps, and both are pinned', () {
      // Pinned to literals on purpose. The two bounds this replaces were
      // written against `kShutdownBudget` itself, so widening the constant —
      // the exact regression they existed to catch — kept them green.
      expect(kShutdownBudget, const Duration(milliseconds: 3250));
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
      expect(kShutdownStepBudgets, hasLength(6));
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
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );
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
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );
      lifecycle.adopt(
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
      expect(lifecycle.abandonedSteps, [
        'agent hook installation',
      ], reason: 'only the step that hangs may be cut off');
      expect(
        lifecycle.skippedSteps,
        isEmpty,
        reason: 'a hanging step helped itself to the shared budget',
      );
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
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );
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

    test(
      'a clean shutdown is far inside Loop 55\'s envelope',
      () async {
        final lifecycle = AppLifecycle(container);
        final natives = FakeNatives();
        await lifecycle.startSystemIntegration(
          endProcess: () {},
          registerOsQuit: (_) {},
          adapters: natives.adapters,
        );

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
          : false,
    );
  });

  group('idempotence', () {
    test('a second shutdown is the same shutdown', () async {
      final lifecycle = AppLifecycle(container);
      final natives = FakeNatives();
      await lifecycle.startSystemIntegration(
        endProcess: () {},
        registerOsQuit: (_) {},
        adapters: natives.adapters,
      );

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

      await service.quit();

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

      expect(natives.window.destroyed, isTrue);
      expect(isDisposed(container), isTrue);
    });
  });

  group('the agents\' hooks are installed behind the first frame', () {
    test('the sweep does not start until the gate is released', () async {
      final sweeps = <int>[];
      final scoped = ProviderContainer(
        overrides: [
          agentHooksAtHostProvider.overrideWithValue(true),
          localHostSessionAccessProvider.overrideWithValue(null),
          agentHookInstallationServiceProvider.overrideWith(
            (ref) => _RecordingHookService(ref, sweeps),
          ),
        ],
      );
      addTearDown(scoped.dispose);
      final lifecycle = AppLifecycle(scoped);
      final gate = Completer<void>();

      lifecycle.installAgentHooks(
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
      expect(scoped.read(agentHookInstallationReportProvider).swept, isFalse);

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
          agentHooksAtHostProvider.overrideWithValue(true),
          localHostSessionAccessProvider.overrideWithValue(null),
          agentHookInstallationServiceProvider.overrideWith(
            (ref) => _RecordingHookService(ref, sweeps),
          ),
        ],
      );
      addTearDown(scoped.dispose);

      AppLifecycle(scoped).installAgentHooks(
        afterFirstFrame: () => Future<void>.error(StateError('no binding')),
      );
      await pumpEventQueue();

      expect(sweeps, [1]);
    });

    test('the sweep waits for the session host\'s start, too', () async {
      // Local agents are given the host's endpoint, which does not exist until
      // the host is up: a sweep before that would install the spool alone.
      final sweeps = <int>[];
      final starting = Completer<HostDeployment?>();
      final scoped = ProviderContainer(
        overrides: [
          agentHooksAtHostProvider.overrideWithValue(true),
          localHostSessionAccessProvider.overrideWithValue(null),
          agentHookInstallationServiceProvider.overrideWith(
            (ref) => _RecordingHookService(ref, sweeps),
          ),
          localHostStartupProvider.overrideWithValue(starting.future),
        ],
      );
      addTearDown(scoped.dispose);

      AppLifecycle(
        scoped,
      ).installAgentHooks(afterFirstFrame: () async {});
      await pumpEventQueue();
      expect(sweeps, isEmpty, reason: 'the host has not started yet');

      starting.complete(null);
      await pumpEventQueue();
      expect(sweeps, [1]);
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

