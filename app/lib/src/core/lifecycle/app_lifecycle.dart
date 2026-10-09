import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../features/agents/application/acp_agent_icon_backfill.dart';
import '../../features/agents/application/agent_hook_installation_service.dart';
import '../../features/agents/application/agent_mcp_entry_service.dart';
import '../../features/agents/application/agent_skill_installation_service.dart';
import '../../features/agents/application/agent_hook_endpoint_healer.dart';
import '../../features/agents/application/agent_hook_sweep.dart';
import '../../features/agents/application/host_hook_endpoint.dart';
import '../../features/agents/application/agent_installations_controller.dart';
import '../../features/agents/application/agent_path_repair_providers.dart';
import '../../features/notifications/application/notification_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/remote/application/remote_access_controller.dart';
import '../../features/system/native_adapters.dart';
import '../../features/system/system_integration_service.dart';
import '../../features/terminal/application/local_host_startup.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../capabilities/capabilities.dart';
import '../data/data_providers.dart';
import '../data/metadata_keys.dart';
import '../logging/memory_census_source.dart';
import '../probe/probe_mode.dart';
import 'package:karmashala_core/logging.dart';
import 'before_quit.dart';
import 'server_session.dart';

/// The deadline for the whole ordered shutdown, after which the app closes
/// regardless. The sum of the per-step caps: one hang cannot starve the rest.
const kShutdownBudget = Duration(milliseconds: 3250);

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

/// What a switch of server gives the session it leaves to close — its data
/// link, shared host link and scout — before it falls back to a relaunch
/// (plan step 14). Longer than quit's slice: a switch has a window to keep.
const kSwitchCloseBudget = Duration(seconds: 10);

/// What a switch gives a hook rewrite in flight, and the endpoint retirement.
/// Longer than quit's: nothing is racing a process exit.
const _kSwitchHookBudget = Duration(seconds: 2);

/// Every step's slice, in order — the arithmetic behind [kShutdownBudget],
/// written down so a change to one of them cannot silently widen the deadline.
const kShutdownStepBudgets = <String, Duration>{
  'agent hook installation': _kHookStepBudget,
  'agent hook uninstall': _kHookStepBudget,
  'background watchers': _kStepBudget,
  'system integration': _kStepBudget,
  'terminal processes': _kTerminalStepBudget,
  'provider teardown': _kContainerStepBudget,
};

/// The single owner of everything bootstrap creates. Shutdown runs one way,
/// outermost first, each step bounded — one that throws or hangs is logged.
class AppLifecycle {
  /// [stopwatch] is the seam the budget is measured through, so a test spends it
  /// on a clock it controls rather than on a busy machine's wall clock.
  ///
  /// [session] is the server session [container] belongs to, whose `close()`
  /// is the container's part of the shutdown. Without one (a test's bare
  /// container) the container is wrapped in a session that owns only it.
  AppLifecycle(
    ProviderContainer container, {
    ServerSession? session,
    AppLogger? logger,
    Duration? shutdownBudget,
    Stopwatch? stopwatch,
  }) : assert(session == null || identical(session.container, container)),
       _logger = logger ?? AppLogger.named('lifecycle'),
       _session =
           session ??
           ServerSession.ofContainer(
             container,
             logger: logger ?? AppLogger.named('lifecycle'),
           ),
       _shutdownBudget = shutdownBudget ?? kShutdownBudget,
       // ignore: prefer_initializing_formals — named for the doc above.
       _stopwatch = stopwatch;

  /// A lifecycle with no session yet: a client that hosts no server and has
  /// no machine chosen. The first pairing's switch adopts one.
  AppLifecycle.withoutSession({AppLogger? logger})
    : _logger = logger ?? AppLogger.named('lifecycle'),
      _session = null,
      _shutdownBudget = kShutdownBudget,
      _stopwatch = null;

  /// The server session every step acts on. Null between a switch's
  /// [leaveSession] and its [adoptSession] (plan step 14).
  ServerSession? _session;

  /// The open session's container. Only read while one is open: every path
  /// that can run between sessions checks [_session] first.
  ProviderContainer get _container {
    final session = _session;
    if (session == null) throw StateError('No server session is open.');
    return session.container;
  }

  /// The [leaveSession] in progress, if any.
  Future<bool>? _leaving;

  final AppLogger _logger;
  final Duration _shutdownBudget;
  final Stopwatch? _stopwatch;

  SystemIntegrationService? _systemIntegration;
  MemoryCensusLogger? _memoryCensus;
  Future<void>? _hookInstallation;
  AgentHookEndpointHealer? _hookHealer;
  Future<void>? _shutdown;

  /// What rewrites a local endpoint file deleted while the app runs; null
  /// before the hooks are installed, in a probe, and after a quit or switch.
  AgentHookEndpointHealer? get hookEndpointHealer => _hookHealer;

  /// Stops the healer; done when a check it had running is, so the retirement
  /// step that follows cannot be undone by it.
  Future<void> _stopHookHealer() {
    final stopped = _hookHealer?.stop() ?? Future<void>.value();
    _hookHealer = null;
    return stopped;
  }

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

  /// Whether this instance is a probe, which leaves every global store alone.
  /// Read once: a probe is the process's, whichever server it is a client of.
  bool get isProbe => _isProbe ??= _container.read(probeModeProvider).enabled;
  bool? _isProbe;

  /// The server session open now; null mid-switch.
  ServerSession? get session => _session;

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
    // Mounting the remote-access controller here keeps the server's config
    // in step with what only this app knows (its SSH relays, Notes).
    _container.read(remoteAccessControllerProvider);
    _systemIntegration = service;
    _container.read(systemIntegrationProvider.notifier).adopt(service);
    await service.init();
    return service;
  }

  /// Installs the agents' status hooks — pointed at the server's endpoint — in
  /// the background and retains the future, so shutdown can wait for a config
  /// rewrite rather than cut it off.
  void installAgentHooks({Future<void> Function()? afterFirstFrame}) {
    if (isProbe) {
      _logger.info(
        'Probe: agent hooks are not installed; the real app owns them.',
      );
      return;
    }
    // Skipped when the host's start has already swept the same endpoint.
    _hookInstallation = _sweepAgentHooks(afterFirstFrame, true);
    // Checks nothing until that sweep has installed an endpoint.
    _hookHealer ??= AgentHookEndpointHealer(_container, logger: _logger)
      ..start();
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

  /// One sweep, behind [gate] and the session host's start, with everything it
  /// reports published. Retained so shutdown can wait for a config rewrite
  /// instead of cutting it off.
  Future<void> _sweepAgentHooks(
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
    final endpoint = installableHookEndpoint(_container, appRoute: null);
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

  /// Keeps Karmashala's entry in agy's own MCP file, behind the same gate as
  /// the skills. Unlike them it runs in a probe too: there it writes only
  /// under the probe's own home, never the real one.
  void installAgentMcpEntries({Future<void> Function()? afterFirstFrame}) {
    unawaited(() async {
      if (afterFirstFrame != null) {
        try {
          await afterFirstFrame();
        } on Object catch (error, stack) {
          _logger.warning(
            'Waiting for the first frame before the agent MCP entry failed; '
            'writing it now.',
            error,
            stack,
          );
        }
      }
      try {
        await _container.read(agentMcpEntryServiceProvider).sweep();
      } on Object catch (error, stack) {
        _logger.warning('The agent MCP entry sweep failed.', error, stack);
      }
    }());
  }

  /// The last memory census printed, or null before the first sample — the
  /// reading Settings → Diagnostics shows.
  MemoryCensus? get lastMemoryCensus => _memoryCensus?.lastLogged;

  /// Begins logging what the app is holding. A release build has no VM service
  /// and so no heap snapshot; without this nothing in the process reports its
  /// own footprint and growth can only be guessed at from outside.
  ///
  /// The process's, not a server's: it keeps running across a switch of
  /// server, reading whichever session is open — none, mid-switch — so a
  /// climb from one switch to the next shows in the same log.
  void startMemoryCensus({MemoryCensusLogger? census}) {
    _memoryCensus ??=
        (census ??
              MemoryCensusLogger(
                count: () => takeMemoryCensus(_session?.container),
              ))
          ..start();
  }

  bool get _agentsDiscovered =>
      _container
          .read(appPreferencesProvider)
          .read(MetadataKeys.agentsDiscoveredAt) !=
      null;

  /// Asks the server to verify the stored agent executables and repair the
  /// rows whose path has rotted, and publishes what it found. Every launch: a
  /// path is state, whether it resolves is a measurement. (The server also
  /// checks at its own start, and looks for agents nobody has searched for and
  /// re-reads aged versions there.)
  Future<void> repairAgentPaths({Future<void> Function()? afterFirstFrame}) =>
      _pathRepair ??= _repairAgentPaths(afterFirstFrame);

  Future<void>? _pathRepair;

  Future<void> _repairAgentPaths(Future<void> Function()? gate) async {
    if (!_agentsDiscovered) return;
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
      if (!report.isClean) _logger.info('Agent paths: ${report.summary}');
    } on Object catch (error, stack) {
      // A check that could not run leaves the rows exactly as they were, which
      // is the same state the app was in before this existed.
      _logger.warning('Checking the stored agent paths failed.', error, stack);
    }
    // An ACP agent row kept before its registry icon was stored gets it now;
    // nothing is fetched when every row has one.
    try {
      await _container.read(acpAgentIconBackfillProvider).fillMissing();
    } on Object catch (error, stack) {
      _logger.warning('Filling in agent icons failed.', error, stack);
    }
  }

  /// Takes ownership of components built elsewhere, so there is still exactly
  /// one object that will shut them down.
  void adopt({
    SystemIntegrationService? systemIntegration,
    Future<void>? hookInstallation,
  }) {
    if (systemIntegration != null) _systemIntegration = systemIntegration;
    if (hookInstallation != null) _hookInstallation = hookInstallation;
  }

  /// Before a switch of server, what a quit does before its shutdown: the
  /// before-quit guards asked (unsaved edits, running sessions — they still
  /// say "quit", as they did when a switch was a relaunch), their flushes
  /// run, and the terminal layout saved. False when a guard keeps the session.
  Future<bool> prepareToLeave() async {
    final session = _session;
    if (session == null || isShuttingDown) return false;
    final container = session.container;
    final hooks = container.read(beforeQuitHooksProvider);
    if (!await hooks.confirm()) return false;
    await hooks.flush();
    try {
      if (container.exists(terminalSessionsControllerProvider)) {
        container
            .read(terminalSessionsControllerProvider.notifier)
            .persistLayout();
      }
    } on Object catch (error) {
      _logger.warning('lifecycle: switch: saving the layout failed: $error');
    }
    return true;
  }

  /// **What a switch of server does with the session it leaves** (plan step
  /// 14): the quit steps that belong to the server, not the ones that belong
  /// to the process. In order:
  ///
  /// 0. a skill sweep still running is abandoned;
  /// 1. a hook rewrite in flight is awaited (bounded), since half of another
  ///    application's config is worse than none;
  /// 1b. the hook endpoints are retired by quit's own rule, which leaves
  ///    alone every file this machine's server still answers — see
  ///    [_retireHookEndpoints];
  /// 2. the attention presenter is disposed;
  /// 4. system integration is **detached**, not disposed: the tray, hotkey
  ///    and window listeners stay, and read no container until [adoptSession];
  /// 5. the panes' process trees are reaped (host-backed panes detach);
  /// 6. the session is closed, its link and scout within [closeBudget].
  ///
  /// The memory census keeps running and reads no session meanwhile. Returns
  /// false when the close ran out of time or threw, which the caller answers
  /// with a relaunch. Idempotent while it runs.
  Future<bool> leaveSession({Duration closeBudget = kSwitchCloseBudget}) =>
      _leaving ??= _leave(closeBudget).whenComplete(() => _leaving = null);

  Future<bool> _leave(Duration closeBudget) async {
    final session = _session;
    if (session == null) return true;
    // From here nothing reads the session through [_container]: the census,
    // a quit and the statics all see "none open".
    _session = null;
    final container = session.container;
    final hookInstallation = _hookInstallation;
    // Each is once per session: the next one runs them again.
    _hookInstallation = null;
    _cliSessionImport = null;
    _pathRepair = null;

    _abandonSkillSweep(container);
    final healerStopped = _stopHookHealer();
    await _bounded(
      'agent hook installation',
      () => Future.wait([
        hookInstallation ?? Future<void>.value(),
        healerStopped,
      ]),
      _kSwitchHookBudget,
    );
    await _bounded(
      'agent hook endpoint retirement',
      () => _retireHookEndpoints(container),
      _kSwitchHookBudget,
    );
    await _bounded(
      'background watchers',
      () async => _stopWatchers(container),
      _kStepBudget,
    );
    _systemIntegration?.detach();
    await _bounded(
      'terminal processes',
      () => _reapPanes(container),
      _kTerminalStepBudget,
    );
    try {
      // close() bounds its own wait; the outer bound is for a close that
      // hangs before it gets there.
      return await session
          .close(teardownBudget: closeBudget)
          .timeout(closeBudget + const Duration(seconds: 1));
    } on Object catch (error, stack) {
      _logger.warning(
        'lifecycle: closing the server session failed.',
        error,
        stack,
      );
      return false;
    }
  }

  /// Points every step at [next], the session a switch opened: the next quit
  /// closes it, the census counts it, and system integration follows its
  /// container. A lifecycle already shutting down adopts nothing.
  Future<void> adoptSession(ServerSession next) async {
    if (isShuttingDown) return;
    _session = next;
    final system = _systemIntegration;
    if (system == null) return;
    // As at start-up: mounted beside the OS integration, in the new container.
    next.container.read(remoteAccessControllerProvider);
    await system.rebind(next.container);
  }

  /// Tears the application down in order, within [kShutdownBudget]. Idempotent:
  /// tray Quit, window close and a restart all land here and await one sequence.
  Future<void> shutdown() => _shutdown ??= _runShutdown();

  Future<void> _runShutdown() async {
    final watch = (_stopwatch ?? Stopwatch())..start();

    // Not a step: cancelling a timer cannot hang, so it needs no slice of the
    // budget — and a census tick during teardown would count a half-torn app.
    _memoryCensus?.dispose();

    // Mid-switch there is no session: the switch's own leave is doing the
    // server's steps, and step 6 waits for it.
    final session = _session;
    final container = session?.container;

    // 0. Give up on any skill sweep still running. Not a step: it sets a flag and
    //    returns, so it needs no slice of the budget and cannot be abandoned.
    if (container != null) _abandonSkillSweep(container);
    final healerStopped = _stopHookHealer();

    // 1. A hook rewrite in flight gets a short grace period; it writes another
    //    application's config file, and half of one is worse than none.
    await _step(
      'agent hook installation',
      watch,
      () => Future.wait([
        _hookInstallation ?? Future<void>.value(),
        healerStopped,
      ]),
      cap: _kHookStepBudget,
    );

    // 1b. Retire the callback endpoint: delete the generated per-agent endpoint
    //     files, leaving the config entries — removing those raced the installer.
    //     Only those this session wrote whose receiver quits with the app.
    await _step(
      'agent hook endpoint retirement',
      watch,
      () => container == null
          ? Future<void>.value()
          : _retireHookEndpoints(container),
      cap: _kHookStepBudget,
    );

    // 2. Watchers, so nothing new arrives while the rest closes.
    await _step('background watchers', watch, () async {
      if (container != null) _stopWatchers(container);
    });

    // Remote access has nothing to close here: the phone listener, the
    // beacon, the LAN relay and every device channel are the server's, and
    // outlive the app. This client's own link and scout close with the server
    // session, step 6.

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
      () => container == null ? Future<void>.value() : _reapPanes(container),
      cap: _kTerminalStepBudget,
    );

    // 6-7. The server session: the container's teardowns started, the
    //    container disposed, those awaited within this step's slice together
    //    with the shared link and the scout — then the layout store, the app's
    //    only database, last and whatever the wait did. See ServerSession.close.
    //    Mid-switch, the leave in progress is what is waited for instead.
    final left = _shutdownBudget - watch.elapsed;
    final cap = _kContainerStepBudget < left ? _kContainerStepBudget : left;
    const step = 'provider teardown';
    final finished = session != null
        ? await session.close(teardownBudget: cap)
        : await _awaitLeaving(cap);
    if (cap <= Duration.zero) {
      skippedSteps.add(step);
      _logger.warning(
        'lifecycle: skipped $step — the shutdown budget is spent',
      );
    } else if (!finished) {
      abandonedSteps.add(step);
      _logger.warning(
        'lifecycle: $step did not finish within '
        '${cap.inMilliseconds} ms; closing anyway',
      );
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

  /// Quit step 0 / switch step 0: a flag, so it needs no bound.
  void _abandonSkillSweep(ProviderContainer container) {
    if (container.exists(agentSkillInstallationServiceProvider)) {
      container.read(agentSkillInstallationServiceProvider).abandon();
    }
  }

  /// Step 1b, at quit and at a switch alike: the generated per-agent endpoint
  /// files, not the config entries — and **only those this session wrote
  /// whose receiver goes away with the app**. The files are this app's to
  /// write, by the hook sweep a session that sets up this machine runs; the
  /// server writes only its own `hook.endpoint` beside its data.
  Future<void> _retireHookEndpoints(ProviderContainer container) async {
    // A probe wrote no endpoint, so the files there are the real app's.
    if (_isProbe ??= container.read(probeModeProvider).enabled) return;
    // A client of a server elsewhere wrote none: the files on this machine
    // were written for this machine's server, which keeps running without
    // this window — deleting them silenced its agents.
    if (!_setsUpThisMachine(container)) return;
    // Every file names this machine's server — its hook listener, or a WSL
    // spool it drains (slice 5a) — and that server outlives the app.
    if (container.read(agentHooksAtHostProvider)) return;
    // No server here to hand hooks to: what is on disk names nobody.
    await container
        .read(agentHookInstallationServiceProvider)
        .retireEndpoints();
  }

  /// Whether [container]'s session is this machine's own server. False, and
  /// logged, when that cannot be read: retiring nothing is the safe side.
  bool _setsUpThisMachine(ProviderContainer container) {
    try {
      return container.read(capabilitiesProvider).setsUpThisMachine;
    } on Object catch (error) {
      _logger.warning('lifecycle: reading the capabilities failed: $error');
      return false;
    }
  }

  /// Step 2: nothing new arrives while the rest closes.
  void _stopWatchers(ProviderContainer container) {
    if (container.exists(attentionPresenterProvider)) {
      container.read(attentionPresenterProvider).dispose();
    }
  }

  /// Step 5: the panes' process trees; never creates the controller.
  Future<void> _reapPanes(ProviderContainer container) =>
      container.exists(terminalSessionsControllerProvider)
      ? container
            .read(terminalSessionsControllerProvider.notifier)
            .shutdownProcesses()
      : Future<void>.value();

  /// Quit's step 6 while a switch is between sessions: the leave in progress,
  /// within [cap]. True when there is none.
  Future<bool> _awaitLeaving(Duration cap) async {
    final leaving = _leaving;
    if (leaving == null) return true;
    if (cap <= Duration.zero) return false;
    try {
      return await leaving.timeout(cap);
    } on TimeoutException {
      return false;
    }
  }

  /// One switch step, bounded by [cap]; one that throws or hangs is logged.
  Future<void> _bounded(
    String name,
    Future<void> Function() action,
    Duration cap,
  ) async {
    try {
      await action().timeout(cap);
    } on TimeoutException {
      _logger.warning(
        'lifecycle: switch: $name did not finish within '
        '${cap.inMilliseconds} ms; going on',
      );
    } on Object catch (error, stack) {
      _logger.warning('lifecycle: switch: $name failed.', error, stack);
    }
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
