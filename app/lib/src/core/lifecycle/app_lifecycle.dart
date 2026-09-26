import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../features/agents/application/agent_hook_installation_service.dart';
import '../../features/agents/application/agent_skill_installation_service.dart';
import '../../features/agents/application/agent_hook_intake.dart';
import '../../features/agents/application/agent_hook_sweep.dart';
import '../../features/agents/application/host_hook_endpoint.dart';
import '../../features/mcp/control_server_restart.dart';
import '../../features/agents/application/agent_installations_controller.dart';
import '../../features/agents/application/agent_path_repair_providers.dart';
import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/mcp/host_agent_tools.dart';
import '../../features/mcp/launcher_control_server.dart';
import '../../features/notifications/application/notification_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/remote/application/remote_access_controller.dart';
import '../../features/remote/relay_local/local_relay_providers.dart';
import '../../features/sessions/application/session_engine_provider.dart';
import '../../features/ssh/application/ssh_providers.dart';
import '../../features/system/native_adapters.dart';
import '../../features/system/system_integration_service.dart';
import '../../features/terminal/application/local_host_startup.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../database/database_providers.dart';
import '../logging/memory_census_source.dart';
import '../probe/probe_mode.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_store/database.dart';

/// The deadline for the whole ordered shutdown, after which the app closes
/// regardless. The sum of the per-step caps: one hang cannot starve the rest.
const kShutdownBudget = Duration(milliseconds: 3550);

/// What one shutdown step gets before it is abandoned.
const _kStepBudget = Duration(milliseconds: 100);

/// The hook rewrite gets longer: the only step that touches another
/// application's files, and the only one where being cut off beats being slow.
const _kHookStepBudget = Duration(milliseconds: 150);

/// Reaping the panes' processes gets the longest slice: it spawns a
/// `taskkill` per live pane, and starting one Windows binary alone costs ~1 s.
const _kTerminalStepBudget = Duration(milliseconds: 2500);

/// What the teardowns that disposing the container *starts* get: one SSH socket
/// close per pooled connection, and one agent child process stop per active run.
const _kContainerStepBudget = Duration(milliseconds: 250);

/// What writing the queued log lines to disk gets, and it is deliberately
/// **not** part of [kShutdownBudget] — see [AppLifecycle.flushLog].
const kLogFlushBudget = Duration(seconds: 1);

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

/// The single owner of everything bootstrap creates. Shutdown runs one way,
/// outermost first, each step bounded — one that throws or hangs is logged.
class AppLifecycle {
  /// [stopwatch] is the seam the budget is measured through, so a test spends it
  /// on a clock it controls rather than on a busy machine's wall clock.
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
  HostAgentTools? _hostAgentTools;
  MemoryCensusLogger? _memoryCensus;
  Future<void>? _hookInstallation;
  Future<void>? _shutdown;

  /// The steps the last [shutdown] cut off at their own cap, in order. *Which*
  /// step was abandoned is worth asserting on; wall-clock milliseconds are not.
  final List<String> abandonedSteps = <String>[];

  /// The steps that never ran because the overall budget was already spent — the
  /// failure the per-step slices exist to prevent, so it is a list to assert on.
  final List<String> skippedSteps = <String>[];

  /// How long the last completed [shutdown] took. Measured rather than
  /// asserted: the budget above is only meaningful if someone reads this.
  Duration? lastShutdownDuration;

  SystemIntegrationService? get systemIntegration => _systemIntegration;
  LauncherControlServer? get controlServer => _controlServer;

  /// Whether the session host serves agents' tools this run, so no control
  /// server was started.
  bool get agentToolsAtHost => _hostAgentTools != null;

  /// Whether this instance is a probe, which leaves every global store alone.
  bool get isProbe => _container.read(probeModeProvider).enabled;

  /// Whether [shutdown] has been started. Nothing new should be adopted after.
  bool get isShuttingDown => _shutdown != null;

  /// Creates and initializes the desktop OS integration, wiring its Quit to
  /// [shutdown] so the app tears down in order before the window is destroyed.
  Future<SystemIntegrationService> startSystemIntegration({
    NativeAdapters? adapters,
    OsQuitRegistrar? registerOsQuit,
    void Function()? endProcess,
  }) async {
    final service = SystemIntegrationService(
      _container,
      adapters: adapters,
      onQuitRequested: shutdown,
      registerOsQuit: registerOsQuit,
      endProcess: endProcess,
    );
    // Mounting the remote-access controller here is what makes "enabled last
    // run" mean "listening this run". Off by default, it starts nothing.
    _container.read(remoteAccessControllerProvider);
    _systemIntegration = service;
    _container.read(systemIntegrationProvider.notifier).adopt(service);
    await service.init();
    return service;
  }

  /// Starts the local control server and retains it *before* `start()` returns,
  /// which publishes the handshake part-way. `null` if it never started at all
  /// — and whenever the session host serves agents' tools instead.
  Future<LauncherControlServer?> startControlServer({
    LauncherControlServer? server,
  }) async {
    if (server == null && _container.read(agentToolsAtHostProvider)) {
      final atHost = HostAgentTools(_container, logger: _logger);
      _hostAgentTools = atHost;
      try {
        if (!await atHost.start()) _hostAgentTools = null;
      } on Object catch (error, stack) {
        _logger.warning(
          'Agent tools at the host failed to start.',
          error,
          stack,
        );
      }
      return null;
    }
    final instance =
        server ?? LauncherControlServer(_container, logger: _logger);
    // Before the await: a partially started server may hold a port and files,
    // and `stop()` is safe on one that never bound.
    _controlServer = instance;
    // Published so Settings can restart the one that is actually up.
    _container.read(controlServerHandleProvider.notifier).set(instance);
    try {
      await instance.start();
      return instance;
    } on Object catch (error, stack) {
      _logger.warning('Launcher control server failed to start.', error, stack);
      return null;
    }
  }

  /// Installs the agents' status hooks in the background and retains the future,
  /// so shutdown can wait for a config rewrite rather than cut it off.
  void installAgentHooks(
    LauncherControlServer? server, {
    Future<void> Function()? afterFirstFrame,
  }) {
    if (isProbe) {
      _logger.info(
        'Probe: agent hooks are not installed; the real app owns them.',
      );
      return;
    }
    // The WSL switch usually does not exist yet when the app launches, so the
    // first sweep skips WSL; the server says when it binds and a re-sweep is free.
    server?.onWslInterfaceBound = () {
      _logger.info('The WSL switch is up; installing hooks for it now.');
      _installAgentHooksNow(server);
    };
    // Skipped when the host's start has already swept the same endpoint.
    _installAgentHooksNow(server, gate: afterFirstFrame, unlessCurrent: true);
  }

  /// Starts, or adopts, this machine's session host now rather than on the
  /// first host-backed pane — see [localHostStartupProvider]. Nothing when local
  /// panes are not host-backed or no host may be reached; never throws.
  void startLocalHost() => _container.read(localHostStartupProvider);

  /// The one CLI-session import of this run, behind [afterFirstFrame] — the walk
  /// is one WSL round trip per entry. Nothing waits on it, a throwing gate least.
  Future<void> importCliSessions({Future<void> Function()? afterFirstFrame}) =>
      _cliSessionImport ??= _importCliSessions(afterFirstFrame);

  Future<void>? _cliSessionImport;

  Future<void> _importCliSessions(Future<void> Function()? gate) async {
    if (gate != null) {
      try {
        await gate();
      } on Object catch (error, stack) {
        _logger.warning(
          'Waiting for the first frame before importing CLI sessions failed; '
          'importing now.',
          error,
          stack,
        );
      }
    }
    try {
      final summary = await _container
          .read(projectsControllerProvider.notifier)
          .importCliSessionsOnce();
      _logger.info('CLI session import: ${summary.sessions} imported.');
    } on Object catch (error, stack) {
      // The stores are somebody else's files and may be absent, locked or on an
      // unreachable share. The workspace is still usable without them.
      _logger.warning('Could not import CLI sessions.', error, stack);
    }
  }

  void _installAgentHooksNow(
    LauncherControlServer? server, {
    Future<void> Function()? gate,
    bool unlessCurrent = false,
  }) {
    _hookInstallation = _sweepAgentHooks(server, gate, unlessCurrent);
  }

  /// One sweep, behind [gate] and the session host's start, with everything it
  /// reports published. Retained so shutdown can wait for a config rewrite
  /// instead of cutting it off.
  Future<void> _sweepAgentHooks(
    LauncherControlServer? server,
    Future<void> Function()? gate,
    bool unlessCurrent,
  ) async {
    if (gate != null) {
      try {
        await gate();
      } on Object catch (error, stack) {
        // A gate that throws must not cost the user their hooks: the sweep is
        // the point and the gate is only about *when*.
        _logger.warning(
          'Waiting for the first frame before installing agent hooks failed; '
          'installing now.',
          error,
          stack,
        );
      }
    }
    // The host first: while hooks go there, its endpoint is what agents are
    // given, and before it has started there is none to give.
    await _container.read(localHostStartupProvider);
    final endpoint = installableHookEndpoint(
      _container,
      appRoute: server?.hookEndpoint,
    );
    if (endpoint == null) return;
    await sweepAgentHooks(
      _container,
      endpoint,
      logger: _logger,
      unlessCurrent: unlessCurrent,
    );
  }

  /// Installs Karmashala's skills into every agent CLI that declares a root,
  /// behind the hooks' gate. Each file is staged and renamed, so a quit is safe.
  void installAgentSkills({Future<void> Function()? afterFirstFrame}) {
    if (isProbe) {
      _logger.info('Probe: agent skills are not installed.');
      return;
    }
    unawaited(_sweepAgentSkills(afterFirstFrame));
  }

  Future<void> _sweepAgentSkills(Future<void> Function()? gate) async {
    if (gate != null) {
      try {
        await gate();
      } on Object catch (error, stack) {
        // The gate is only about *when*; a gate that throws must not cost the
        // user their skills.
        _logger.warning(
          'Waiting for the first frame before installing agent skills failed; '
          'installing now.',
          error,
          stack,
        );
      }
    }
    try {
      await _container.read(agentSkillInstallationServiceProvider).sweep();
    } on Object catch (error, stack) {
      // Somebody else's home directory. The app is entirely usable without a
      // skill in it, and the next launch sweeps again.
      _logger.warning('Agent skill installation failed.', error, stack);
    }
  }

  /// The last memory census printed, or null before the first sample — the
  /// reading Settings → Diagnostics shows.
  MemoryCensus? get lastMemoryCensus => _memoryCensus?.lastLogged;

  /// Begins logging what the app is holding. A release build has no VM service
  /// and so no heap snapshot; without this nothing in the process reports its
  /// own footprint and growth can only be guessed at from outside.
  void startMemoryCensus({MemoryCensusLogger? census}) {
    _memoryCensus ??=
        (census ??
              MemoryCensusLogger(count: () => takeMemoryCensus(_container)))
          ..start();
  }

  /// Looks in the background for agents this workspace has never searched for.
  /// Skipped on a never-discovered workspace: its first-run scan is doing this.
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

  /// Verifies the stored agent executables and repairs the rows whose path has
  /// rotted. Every launch: a path is state, whether it resolves is a measurement.
  Future<void> repairAgentPaths({Future<void> Function()? afterFirstFrame}) =>
      _pathRepair ??= _repairAgentPaths(afterFirstFrame);

  Future<void>? _pathRepair;

  Future<void> _repairAgentPaths(Future<void> Function()? gate) async {
    if (_container
            .read(databaseProvider)
            .readMetadata(MetadataKeys.agentsDiscoveredAt) ==
        null) {
      return;
    }
    if (gate != null) {
      try {
        await gate();
      } on Object catch (error, stack) {
        _logger.warning(
          'Waiting for the first frame before checking the agent paths '
          'failed; checking now.',
          error,
          stack,
        );
      }
    }
    try {
      final report = await _container
          .read(agentInstallationsControllerProvider.notifier)
          .repairBrokenPaths();
      // Published, not just logged: an unrepaired row is something only the user
      // can fix, and "not installed" and "cannot be reached" are different answers.
      _container.read(agentPathRepairProvider.notifier).set(report);
      if (report.isClean) return;
      _logger.info('Agent paths: ${report.summary}');
    } on Object catch (error, stack) {
      // A check that could not run leaves the rows exactly as they were, which
      // is the same state the app was in before this existed.
      _logger.warning('Checking the stored agent paths failed.', error, stack);
    }
  }

  /// Re-reads the recorded agent versions whose reading has aged out, after the
  /// path check. The launch is the occasion; the row's recorded age is the gate.
  Future<void> refreshAgentVersions({
    Future<void> Function()? afterFirstFrame,
  }) => _versionRefresh ??= _refreshAgentVersions(afterFirstFrame);

  Future<void>? _versionRefresh;

  Future<void> _refreshAgentVersions(Future<void> Function()? gate) async {
    await repairAgentPaths(afterFirstFrame: gate);
    // Same rule as [startAgentDiscovery] and the path check: a workspace that
    // has never discovered anything has its own first-run scan writing these
    // very rows, and racing it would probe everything twice.
    if (_container
            .read(databaseProvider)
            .readMetadata(MetadataKeys.agentsDiscoveredAt) ==
        null) {
      return;
    }
    try {
      final changed = await _container
          .read(agentInstallationsControllerProvider.notifier)
          .refreshStaleVersions();
      if (changed.isEmpty) return;
      _logger.info('Agent versions: ${changed.join(', ')}.');
    } on Object catch (error, stack) {
      // A reading that could not be taken leaves every row exactly as it was,
      // wearing the age it already had.
      _logger.warning('Re-reading the agent versions failed.', error, stack);
    }
  }

  /// The one conversation-index catch-up this database will ever have. Behind
  /// [importCliSessions]: both walk the CLI stores, and racing pays each twice.
  Future<void> backfillConversationIndex({
    Future<void> Function()? afterFirstFrame,
  }) => _conversationBackfill ??= _backfillConversationIndex(afterFirstFrame);

  Future<void>? _conversationBackfill;

  Future<void> _backfillConversationIndex(Future<void> Function()? gate) async {
    await importCliSessions(afterFirstFrame: gate);
    try {
      final backfill = _container.read(conversationIndexBackfillProvider);
      if (backfill.isDone) return;
      final indexed = await backfill.runOnce();
      _logger.info(
        'Conversation index: $indexed conversations caught up '
        'in ${backfill.walks} store walk(s).',
      );
    } on Object catch (error, stack) {
      // The transcripts are somebody else's files and may be absent, locked or
      // on an unreachable share. Search answers with fewer conversations; the
      // workspace is unaffected.
      _logger.warning(
        'Could not back-fill the conversation index.',
        error,
        stack,
      );
    }
  }

  /// Takes ownership of components built elsewhere, so there is still exactly
  /// one object that will shut them down.
  void adopt({
    LauncherControlServer? controlServer,
    SystemIntegrationService? systemIntegration,
    Future<void>? hookInstallation,
  }) {
    if (controlServer != null) _controlServer = controlServer;
    if (systemIntegration != null) _systemIntegration = systemIntegration;
    if (hookInstallation != null) _hookInstallation = hookInstallation;
  }

  /// Tears the application down in order, within [kShutdownBudget]. Idempotent:
  /// tray Quit, window close and a restart all land here and await one sequence.
  Future<void> shutdown() => _shutdown ??= _runShutdown();

  Future<void> _runShutdown() async {
    final watch = (_stopwatch ?? Stopwatch())..start();

    // Not a step: cancelling a timer cannot hang, so it needs no slice of the
    // budget — and a census tick during teardown would count a half-torn app.
    _memoryCensus?.dispose();

    // 0. Give up on any skill sweep still running. Not a step: it sets a flag and
    //    returns, so it needs no slice of the budget and cannot be abandoned.
    if (_container.exists(agentSkillInstallationServiceProvider)) {
      _container.read(agentSkillInstallationServiceProvider).abandon();
    }

    // 1. A hook rewrite in flight gets a short grace period; it writes another
    //    application's config file, and half of one is worse than none.
    await _step(
      'agent hook installation',
      watch,
      () => _hookInstallation ?? Future<void>.value(),
      cap: _kHookStepBudget,
    );

    // 1b. Retire the callback endpoint: delete the generated per-agent endpoint
    //     files, leaving the config entries — removing those raced the installer.
    await _step('agent hook endpoint retirement', watch, () async {
      // A probe wrote no endpoint, so the files there are the real app's.
      if (isProbe) return;
      // Stop draining first. `retireEndpoints` deletes the spool directories,
      // and a tick that ran into a directory being removed underneath it would
      // do no harm but would spend the shutdown budget finding that out.
      if (_container.exists(agentHookSpoolDrainerProvider)) {
        _container.read(agentHookSpoolDrainerProvider).dispose();
      }
      // Hooks posting to the session host keep going to it with the app shut.
      await _container
          .read(agentHookInstallationServiceProvider)
          .retireEndpoints(
            keepLocal: _container.read(agentHooksAtHostProvider),
          );
    }, cap: _kHookStepBudget);

    // 2. Watchers, so nothing new arrives while the rest closes.
    await _step('background watchers', watch, () async {
      if (_container.exists(agentStatusWatcherProvider)) {
        _container.read(agentStatusWatcherProvider).dispose();
      }
    });

    // 2c. Remote access: the LAN listener, the beacon and every device channel.
    //     Closing cleanly lets a phone back off instead of reconnecting forever.
    await _step('remote access', watch, () async {
      if (_container.exists(remoteAccessControllerProvider)) {
        await _container.read(remoteAccessControllerProvider).shutdown();
      }
    });

    // 2d. The embedded local relay, after the host service stopped dialling it:
    //     close the socket so the port is free the moment the app is gone.
    await _step('local relay', watch, () async {
      if (_container.exists(localRelayServiceProvider)) {
        await _container.read(localRelayServiceProvider).stop();
      }
    });

    // 3. The control server. `stop()` deletes the handshake — the whole reason
    //    this owner exists.
    await _step('control server', watch, () async {
      await _controlServer?.stop();
      await _hostAgentTools?.stop();
    });

    // 4. The OS integration: hotkeys, tray, listeners.
    await _step(
      'system integration',
      watch,
      () => _systemIntegration?.dispose() ?? Future<void>.value(),
    );

    // 5. The panes' process trees, `taskkill /T` per pane. The one step whose
    //    work is another process, and where not waiting leaves the user's running.
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

    // 6. The container. `dispose()` is synchronous and runs unconditionally; what
    //    it *starts* is not, so those begin here, where the wait is budgeted.
    final pending = _startContainerTeardowns();
    final database = _databaseOrNull();
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

    // 7. The database handle, last. Not a `_step`: `close()` is one synchronous
    //    call, and `exit(0)` leaves a `-wal`/`-shm` for the next launch to recover.
    try {
      database?.close();
    } on Object catch (error) {
      // A handle already closed, or one a teardown is still inside. The next
      // launch recovers from the journal exactly as it did before.
      _logger.warning('lifecycle: closing the database failed reason=$error');
    }

    watch.stop();
    lastShutdownDuration = watch.elapsed;
    _logger.info('lifecycle: shutdown in ${watch.elapsedMilliseconds} ms.');
    await flushLog();
  }

  /// Puts what has been logged on disk, **outside [kShutdownBudget]**: as a step
  /// it was skipped by exactly the shutdowns whose account was worth reading.
  Future<void> flushLog() async {
    try {
      await Diagnostics.instance.flushFile().timeout(kLogFlushBudget);
    } on Object {
      // A sink that cannot be written must not hold the app open. Nothing is
      // logged about it: there is nowhere left for that line to go.
    }
  }

  /// The database this container was given, or null when it has none. Read
  /// *before* `dispose()`, which leaves the container unreadable.
  AppDatabase? _databaseOrNull() {
    try {
      return _container.read(databaseProvider);
    } on Object {
      // Companion mode and a few tools build a container with no database.
      return null;
    }
  }

  /// Starts the teardowns that container disposal would otherwise fire and
  /// forget. Read and started before `dispose()`, so its own hooks are no-ops.
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
      skippedSteps.add(name);
      _logger.warning(
        'lifecycle: skipped $name — the shutdown budget is spent',
      );
      return;
    }
    try {
      await action().timeout(remaining);
    } on TimeoutException {
      abandonedSteps.add(name);
      _logger.warning(
        'lifecycle: $name did not finish within '
        '${remaining.inMilliseconds} ms; closing anyway',
      );
    } on Object catch (error, stack) {
      _logger.warning('lifecycle: $name failed.', error, stack);
    }
  }
}
