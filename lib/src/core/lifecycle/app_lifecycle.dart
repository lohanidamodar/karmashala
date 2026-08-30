import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/application/agent_hook_installation_service.dart';
import '../../features/mcp/launcher_control_server.dart';
import '../../features/notifications/application/notification_providers.dart';
import '../../features/system/native_adapters.dart';
import '../../features/system/system_integration_service.dart';
import '../logging/app_logger.dart';

/// The deadline for the whole ordered shutdown, after which the app closes
/// regardless.
///
/// Quitting is measured, not assumed: Loop 55 timed a graceful quit at
/// 225–396 ms end to end, and Loop 48 found a build that would not exit at all
/// because one component could not be shut down. Cleanup that is worth doing is
/// worth doing quickly; cleanup that hangs is worth abandoning. Everything in
/// the sequence is either an in-memory teardown or a single file delete, so this
/// is generous — it exists to bound the pathological case, not the normal one.
///
/// It is the sum of the per-step caps below, deliberately: a **shared** budget
/// let the first step starve every later one, which meant one hung hook rewrite
/// took the handshake deletion with it — the single step this owner exists for.
/// Each step gets its own slice instead, so a hang costs that step and nothing
/// else.
const kShutdownBudget = Duration(milliseconds: 450);

/// What one shutdown step gets before it is abandoned.
const _kStepBudget = Duration(milliseconds: 100);

/// The hook rewrite gets longer: it is the only step that touches another
/// application's files, and the only one where being cut off is worse than
/// being slow.
const _kHookStepBudget = Duration(milliseconds: 150);

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
/// 5. **The provider container** — last, because every step above reads from it.
///
/// Each step is bounded and independent: one that throws or hangs is logged and
/// the next one still runs.
class AppLifecycle {
  AppLifecycle(this._container, {AppLogger? logger, Duration? shutdownBudget})
    : _logger = logger ?? AppLogger.named('lifecycle'),
      _shutdownBudget = shutdownBudget ?? kShutdownBudget;

  final ProviderContainer _container;
  final AppLogger _logger;
  final Duration _shutdownBudget;

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
    _systemIntegration = service;
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
    final watch = Stopwatch()..start();

    // 1. A hook rewrite in flight gets a short grace period; it writes another
    //    application's config file, and half of one is worse than none.
    await _step(
      'agent hook installation',
      watch,
      () => _hookInstallation ?? Future<void>.value(),
      cap: _kHookStepBudget,
    );

    // 2. Watchers, so nothing new arrives while the rest closes.
    await _step('background watchers', watch, () async {
      if (_container.exists(agentStatusWatcherProvider)) {
        _container.read(agentStatusWatcherProvider).dispose();
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

    // 5. The container, unconditionally and outside the budget: it is
    //    synchronous, it cannot hang, and every provider's own teardown hangs
    //    off it.
    try {
      _container.dispose();
    } on Object catch (error, stack) {
      _logger.warning('Disposing the provider container failed.', error, stack);
    }

    watch.stop();
    lastShutdownDuration = watch.elapsed;
    _logger.info('lifecycle: shutdown in ${watch.elapsedMilliseconds} ms.');
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
