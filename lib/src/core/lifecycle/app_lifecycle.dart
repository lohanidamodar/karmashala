import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/application/agent_hook_installation_service.dart';
import '../../features/agents/application/agent_installations_controller.dart';
import '../../features/mcp/launcher_control_server.dart';
import '../../features/notifications/application/notification_providers.dart';
import '../../features/remote/application/remote_access_controller.dart';
import '../../features/remote/relay_local/local_relay_providers.dart';
import '../../features/sessions/application/session_engine_provider.dart';
import '../../features/ssh/application/ssh_providers.dart';
import '../../features/system/native_adapters.dart';
import '../../features/system/system_integration_service.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../database/database_providers.dart';
import '../logging/app_logger.dart';
import '../logging/diagnostics.dart';

/// The deadline for the whole ordered shutdown, after which the app closes
/// regardless.
///
/// Quitting is measured, not assumed: Loop 55 timed a graceful quit at
/// 225–396 ms end to end, and Loop 48 found a build that would not exit at all
/// because one component could not be shut down. Cleanup that is worth doing is
/// worth doing quickly; cleanup that hangs is worth abandoning. **This is the
/// pathological ceiling, not the expected cost** — every step here completes in
/// microseconds when nothing is wrong, and the normal quit stays where Loop 55
/// measured it.
///
/// It is the sum of the per-step caps below, deliberately: a **shared** budget
/// let the first step starve every later one, which meant one hung hook rewrite
/// took the handshake deletion with it — the single step this owner exists for.
/// Each step gets its own slice instead, so a hang costs that step and nothing
/// else. [kShutdownStepBudgets] is that sum, itemised.
const kShutdownBudget = Duration(milliseconds: 2550);

/// What one shutdown step gets before it is abandoned.
const _kStepBudget = Duration(milliseconds: 100);

/// The hook rewrite gets longer: it is the only step that touches another
/// application's files, and the only one where being cut off is worse than
/// being slow.
const _kHookStepBudget = Duration(milliseconds: 150);

/// Reaping the panes' processes gets the longest slice.
///
/// Every other step is an in-memory teardown or a single file delete. This one
/// spawns `taskkill /PID <pid> /T /F` per live pane (see
/// `killWindowsProcessTree`) — an external process each, run concurrently — and
/// the cost of cutting it short is the thing it exists to prevent: a dev server
/// still holding a port, or a build still holding a file lock, after the app
/// has gone. It is a ceiling, not a wait: the reaps normally land in tens of
/// milliseconds.
const _kTerminalStepBudget = Duration(milliseconds: 1500);

/// What the teardowns that disposing the container *starts* get: one SSH socket
/// close per pooled connection, and one agent child process stop per active run.
const _kContainerStepBudget = Duration(milliseconds: 250);

/// Every step's slice, in order — the arithmetic behind [kShutdownBudget],
/// written down so a change to one of them cannot silently widen the deadline.
const kShutdownStepBudgets = <String, Duration>{
  'agent hook installation': _kHookStepBudget,
  'agent hook uninstall': _kHookStepBudget,
  'background watchers': _kStepBudget,
  'remote access': _kStepBudget,
  'local relay': _kStepBudget,
  'control server': _kStepBudget,
  'system integration': _kStepBudget,
  'terminal processes': _kTerminalStepBudget,
  'provider teardown': _kContainerStepBudget,
};

/// The single owner of everything bootstrap creates.
///
/// Before Loop 61 there was none: `main()` built `SystemIntegrationService` as a
/// temporary expression, kept `LauncherControlServer` in a local whose comment
/// claimed it was retained, and never called `stop()` on it — so a normal quit
/// left the bridge handshake on disk pointing at a port nothing was listening
/// on. Cleanup happened because the process ended, which is not the same thing
/// as cleanup happening.
///
/// ## Order
///
/// Shutdown runs in one direction, outermost first:
///
/// 1. **Hook installation** — it rewrites third-party agents' own config files.
///    Anything else can be interrupted; a half-written config cannot.
/// 2. **Background watchers** — stop producing work for things about to close.
/// 3. **Control server** — closing it deletes the handshake, so no bridge
///    starts up against a dead port. This is the step the app never had.
/// 4. **System integration** — hotkeys released, tray icon removed, listeners
///    detached.
/// 5. **Terminal processes** — the panes' process *trees*, killed and waited
///    for. After the OS integration, because a tray icon that outlives the
///    window is cosmetic and an orphaned dev server is not.
/// 6. **The provider container** — last, because every step above reads from
///    it. Its `dispose()` is synchronous and runs unconditionally, but the
///    teardowns it *starts* are not: `ref.onDispose` takes a callback, not a
///    future, so an SSH socket close and an agent child process were begun and
///    dropped. Those are started here, where the wait for them is budgeted.
///
/// Each step is bounded and independent: one that throws or hangs is logged and
/// the next one still runs.
class AppLifecycle {
  /// [stopwatch] is the seam the budget is measured through. Injected so a test
  /// can spend the budget on a clock it controls instead of waiting out real
  /// milliseconds — a shutdown deadline measured against the wall clock is a
  /// flake looking for a busy machine.
  AppLifecycle(
    this._container, {
    AppLogger? logger,
    Duration? shutdownBudget,
    Stopwatch? stopwatch,
  }) : _logger = logger ?? AppLogger.named('lifecycle'),
       _shutdownBudget = shutdownBudget ?? kShutdownBudget,
       // ignore: prefer_initializing_formals — named for the doc above.
       _stopwatch = stopwatch;

  final ProviderContainer _container;
  final AppLogger _logger;
  final Duration _shutdownBudget;
  final Stopwatch? _stopwatch;

  SystemIntegrationService? _systemIntegration;
  LauncherControlServer? _controlServer;
  Future<void>? _hookInstallation;
  Future<void>? _shutdown;

  /// How long the last completed [shutdown] took. Measured rather than
  /// asserted: the budget above is only meaningful if someone reads this.
  Duration? lastShutdownDuration;

  SystemIntegrationService? get systemIntegration => _systemIntegration;
  LauncherControlServer? get controlServer => _controlServer;

  /// Whether [shutdown] has been started. Nothing new should be adopted after.
  bool get isShuttingDown => _shutdown != null;

  /// Creates and initializes the desktop OS integration, wiring its Quit to
  /// this owner's [shutdown] so a graceful quit tears the app down in order
  /// *before* the window is destroyed.
  Future<SystemIntegrationService> startSystemIntegration({
    NativeAdapters? adapters,
  }) async {
    final service = SystemIntegrationService(
      _container,
      adapters: adapters,
      onQuitRequested: shutdown,
    );
    // Mounting the remote-access controller here is what makes "enabled last
    // run" mean "listening this run". Off by default, it costs one settings
    // read and starts nothing.
    _container.read(remoteAccessControllerProvider);
    _systemIntegration = service;
    _container.read(systemIntegrationProvider.notifier).adopt(service);
    await service.init();
    return service;
  }

  /// Starts the local control server and retains it, so `stop()` has a caller.
  ///
  /// Returns `null` when the server could not be started at all — distinct from
  /// a server that started and withheld privileged RPC, which is a running
  /// server with a [LauncherControlServer.status] to show.
  Future<LauncherControlServer?> startControlServer({
    LauncherControlServer? server,
  }) async {
    final instance =
        server ?? LauncherControlServer(_container, logger: _logger);
    try {
      await instance.start();
      _controlServer = instance;
      return instance;
    } on Object catch (error, stack) {
      _logger.warning('Launcher control server failed to start.', error, stack);
      // Retained anyway: a partially started server may still hold a port, and
      // `stop()` is safe on one that never bound.
      _controlServer = instance;
      return null;
    }
  }

  /// Installs the agents' status hooks in the background and retains the
  /// future, so shutdown can wait for a config rewrite rather than cut it off.
  void installAgentHooks(LauncherControlServer server) {
    // The WSL switch usually does not exist yet when an app that launches with
    // Windows starts, so the first sweep skips every WSL store — and until now
    // nothing ever revisited that decision: the owner's WSL sessions ran all
    // morning with no hooks while the adapter sat there. The server tells us
    // when it finally binds, and the sweep is idempotent to the byte, so
    // running it again costs a config rewrite only where something changed.
    server.onWslInterfaceBound = () {
      _logger.info('The WSL switch is up; installing hooks for it now.');
      _installAgentHooksNow(server);
    };
    _installAgentHooksNow(server);
  }

  void _installAgentHooksNow(LauncherControlServer server) {
    final endpoint = server.hookEndpoint;
    if (endpoint == null) return;
    // Off the startup path: rewriting hooks reads and writes the agents' own
    // config files, and the window should not wait for it. Hooks that land a
    // moment after launch are still hooks; a slower launch is felt every time.
    _hookInstallation = _container
        .read(agentHookInstallationServiceProvider)
        .installAll(endpoint)
        .then(
          (results) {
            final installed = results.where((r) => r.installed).length;
            _logger.info(
              'Agent hooks: $installed installed, '
              '${results.length - installed} skipped.',
            );
          },
          onError: (Object error, StackTrace stack) =>
              _logger.warning('Agent hook installation failed.', error, stack),
        );
  }

  /// Looks for agents this workspace has never searched for, in the background.
  ///
  /// Agent discovery was a single scan at workspace creation, so a descriptor
  /// that joined the registry in an app *upgrade* — `antigravity` in 1.1.4 —
  /// stayed invisible until the user happened to find "Discover agents" in
  /// Settings. This asks only about the `(agent, environment)` pairs with
  /// neither an installation row nor a probe record, so a launch with nothing
  /// new to look for spawns no processes at all.
  ///
  /// Skipped on a workspace that has never discovered anything: that launch's
  /// own first-run scan is doing the same work, and racing it would probe every
  /// agent twice.
  ///
  /// Not awaited and not retained. Each probe is a bounded subprocess with
  /// nothing to tear down, and the window must not wait on WSL to answer.
  void startAgentDiscovery() {
    final database = _container.read(databaseProvider);
    if (database.readMetadata(MetadataKeys.agentsDiscoveredAt) == null) return;
    unawaited(
      _container
          .read(agentInstallationsControllerProvider.notifier)
          .discoverUnprobed()
          .then(
            (found) {
              if (found.isEmpty) return;
              _logger.info(
                'Agent discovery found ${found.length} agent(s) nobody had '
                'looked for yet.',
              );
            },
            onError: (Object error, StackTrace stack) => _logger.warning(
              'Discovery of never-probed agents failed.',
              error,
              stack,
            ),
          ),
    );
  }

  /// Takes ownership of components built elsewhere.
  ///
  /// The app builds almost everything through the methods above, but the two
  /// pieces that need external configuration — a control server pointed at
  /// specific paths, an in-flight hook installation — come in this way, so
  /// there is still exactly one object that will shut them down.
  void adopt({
    LauncherControlServer? controlServer,
    SystemIntegrationService? systemIntegration,
    Future<void>? hookInstallation,
  }) {
    if (controlServer != null) _controlServer = controlServer;
    if (systemIntegration != null) _systemIntegration = systemIntegration;
    if (hookInstallation != null) _hookInstallation = hookInstallation;
  }

  /// Tears the application down in order, within [kShutdownBudget].
  ///
  /// Idempotent and safe to call from more than one exit path — the tray's
  /// Quit, the window's close button and a future restart all land here, and
  /// concurrent callers await the same sequence rather than racing it.
  Future<void> shutdown() => _shutdown ??= _runShutdown();

  Future<void> _runShutdown() async {
    final watch = (_stopwatch ?? Stopwatch())..start();

    // 1. A hook rewrite in flight gets a short grace period; it writes another
    //    application's config file, and half of one is worse than none.
    await _step(
      'agent hook installation',
      watch,
      () => _hookInstallation ?? Future<void>.value(),
      cap: _kHookStepBudget,
    );

    // 1b. Take our hooks back out of the agents' config files (Loop 68, B2):
    //     the endpoint they point at dies with this process, and a stale
    //     curl in someone's settings.json is exactly what the owner would
    //     notice next week.
    await _step('agent hook uninstall', watch, () async {
      await _container
          .read(agentHookInstallationServiceProvider)
          .uninstallAll();
    }, cap: _kHookStepBudget);

    // 2. Watchers, so nothing new arrives while the rest closes.
    await _step('background watchers', watch, () async {
      if (_container.exists(agentStatusWatcherProvider)) {
        _container.read(agentStatusWatcherProvider).dispose();
      }
    });

    // 2c. Remote access (Loop 70): the LAN listener, the beacon and every
    //     device channel. A phone left talking to a dead port would just
    //     reconnect forever; closing cleanly lets it back off properly.
    await _step('remote access', watch, () async {
      if (_container.exists(remoteAccessControllerProvider)) {
        await _container.read(remoteAccessControllerProvider).shutdown();
      }
    });

    // 2d. The embedded local relay (Loop 77), after the host service above
    //     stopped dialling it: close the listening socket so the port is
    //     free the moment the app is gone.
    await _step('local relay', watch, () async {
      if (_container.exists(localRelayServiceProvider)) {
        await _container.read(localRelayServiceProvider).stop();
      }
    });

    // 3. The control server. `stop()` deletes the handshake — the whole reason
    //    this owner exists.
    await _step(
      'control server',
      watch,
      () => _controlServer?.stop() ?? Future<void>.value(),
    );

    // 4. The OS integration: hotkeys, tray, listeners.
    await _step(
      'system integration',
      watch,
      () => _systemIntegration?.dispose() ?? Future<void>.value(),
    );

    // 5. The panes' process trees. Killing them is `taskkill /T` per pane, so
    //    this is the one step whose work is another process rather than a
    //    field being nulled — and the only one where not waiting means leaving
    //    something of the user's running.
    await _step(
      'terminal processes',
      watch,
      () => _container.exists(terminalSessionsControllerProvider)
          ? _container
                .read(terminalSessionsControllerProvider.notifier)
                .shutdownProcesses()
          : Future<void>.value(),
      cap: _kTerminalStepBudget,
    );

    // 6. The container. Its own `dispose()` is synchronous and cannot hang, so
    //    it runs unconditionally — even with the budget spent, because every
    //    provider's teardown hangs off it. What is *not* synchronous is the
    //    work that teardown starts, and Riverpod cannot wait for it:
    //    `ref.onDispose` takes a callback, so the SSH pool's socket closes and
    //    the session engine's agent processes were started and dropped. Both
    //    are idempotent, so starting them here — where the wait is budgeted —
    //    leaves the providers' own hooks as no-ops.
    final pending = _startContainerTeardowns();
    try {
      _container.dispose();
    } on Object catch (error, stack) {
      _logger.warning('Disposing the provider container failed.', error, stack);
    }
    await _step(
      'provider teardown',
      watch,
      () => Future.wait(pending),
      cap: _kContainerStepBudget,
    );

    watch.stop();
    lastShutdownDuration = watch.elapsed;
    _logger.info('lifecycle: shutdown in ${watch.elapsedMilliseconds} ms.');
    // Last, so the line above makes the file: the log sink batches, and a quit
    // that loses its own last 400 ms is a quit whose failures are invisible.
    await _step(
      'log flush',
      watch,
      () => Diagnostics.instance.file?.flush() ?? Future<void>.value(),
      cap: const Duration(seconds: 1),
    );
  }

  /// Starts the teardowns that container disposal would otherwise fire and
  /// forget, returning their futures so the caller can wait for them.
  ///
  /// Read *before* `dispose()`, because a disposed container cannot be read
  /// from; started before it too, so a provider's own `onDispose` finds the
  /// work already done rather than doing it a second time.
  List<Future<void>> _startContainerTeardowns() {
    final pending = <Future<void>>[];
    for (final start in <Future<void> Function()>[
      () => _container.exists(sessionEngineProvider)
          ? _container.read(sessionEngineProvider).dispose()
          : Future<void>.value(),
      () => _container.exists(sshConnectionPoolProvider)
          ? _container.read(sshConnectionPoolProvider).closeAll()
          : Future<void>.value(),
    ]) {
      try {
        pending.add(start());
      } on Object catch (error, stack) {
        _logger.warning(
          'lifecycle: a container teardown failed.',
          error,
          stack,
        );
      }
    }
    return pending;
  }

  /// One shutdown step, bounded by its own slice and by the overall deadline.
  Future<void> _step(
    String name,
    Stopwatch watch,
    Future<void> Function() action, {
    Duration cap = _kStepBudget,
  }) async {
    final left = _shutdownBudget - watch.elapsed;
    var remaining = cap < left ? cap : left;
    if (remaining <= Duration.zero) {
      _logger.warning(
        'lifecycle: skipped $name — the shutdown budget is spent',
      );
      return;
    }
    try {
      await action().timeout(remaining);
    } on TimeoutException {
      _logger.warning(
        'lifecycle: $name did not finish within '
        '${remaining.inMilliseconds} ms; closing anyway',
      );
    } on Object catch (error, stack) {
      _logger.warning('lifecycle: $name failed.', error, stack);
    }
  }
}
