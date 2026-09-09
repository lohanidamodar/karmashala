import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/agents/application/agent_hook_installation_service.dart';
import '../../features/agents/application/agent_skill_installation_service.dart';
import '../../features/agents/application/agent_hook_intake.dart';
import '../../features/agents/application/agent_installations_controller.dart';
import '../../features/agents/application/agent_path_repair_providers.dart';
import '../../features/agents/domain/agent_hook_endpoint.dart';
import '../../features/cli_detection/application/cli_detection_providers.dart';
import '../../features/mcp/launcher_control_server.dart';
import '../../features/notifications/application/notification_providers.dart';
import '../../features/projects/application/projects_controller.dart';
import '../../features/remote/application/remote_access_controller.dart';
import '../../features/remote/relay_local/local_relay_providers.dart';
import '../../features/sessions/application/session_engine_provider.dart';
import '../../features/ssh/application/ssh_providers.dart';
import '../../features/system/native_adapters.dart';
import '../../features/system/system_integration_service.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import '../database/app_database.dart';
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

  /// The steps the last [shutdown] cut off at their own cap, in order.
  ///
  /// Recorded rather than only logged, because *which* step was abandoned is
  /// the property worth holding and wall-clock milliseconds are not: on a
  /// loaded machine the elapsed time is the machine, while a 700 ms shutdown
  /// that skipped the step which deletes the handshake would pass any duration
  /// bound you could pick.
  final List<String> abandonedSteps = <String>[];

  /// The steps that never ran at all because the overall budget was already
  /// spent when their turn came.
  ///
  /// **This is the failure the per-step slices exist to prevent** — one hang
  /// eating the sequence — so it is a list to assert on rather than a warning
  /// in a file nobody opens.
  final List<String> skippedSteps = <String>[];

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
  /// **Retained before it is started, not after.** `start()` publishes the
  /// handshake part-way through — the socket node is already bound, and the WSL
  /// listener and the session-config directory come *after* it — so from the
  /// moment `mcp_bridge.json` appears there is a server with files on disk and
  /// several hundred milliseconds of starting left to do. Assigning this field
  /// only once `start()` returned left that whole window with nothing for step
  /// 3 to stop: it took the `?? Future<void>.value()` branch and logged no
  /// skip, no timeout and no failure, because from its point of view there was
  /// no server. The 2026-09-09 soak measured that as the *usual* outcome of a
  /// quit — 18 of 20 — and this line is half the fix; the other half is
  /// `LauncherControlServer.stop` making an in-flight `start` unwind instead of
  /// republishing what it just removed.
  ///
  /// Returns `null` when the server could not be started at all — distinct from
  /// a server that started and withheld privileged RPC, which is a running
  /// server with a [LauncherControlServer.status] to show.
  Future<LauncherControlServer?> startControlServer({
    LauncherControlServer? server,
  }) async {
    final instance =
        server ?? LauncherControlServer(_container, logger: _logger);
    // Before the await: a partially started server may hold a port and files,
    // and `stop()` is safe on one that never bound.
    _controlServer = instance;
    try {
      await instance.start();
      return instance;
    } on Object catch (error, stack) {
      _logger.warning('Launcher control server failed to start.', error, stack);
      return null;
    }
  }

  /// Installs the agents' status hooks in the background and retains the
  /// future, so shutdown can wait for a config rewrite rather than cut it off.
  ///
  /// [afterFirstFrame], when given, is what the **first** sweep waits behind.
  /// It exists because "in the background" was only ever true of the *await*:
  /// until Loop 78 every file operation on the install path was synchronous, so
  /// the sweep ran on the isolate in one unbroken block between two frames and
  /// the window could not paint until it finished. It measured **1053 ms of a
  /// 1.91 s launch** on the owner's machine — 55% of it, for work no user is
  /// waiting for. Both halves of that are fixed here: the I/O is asynchronous
  /// (`AgentHookInstaller`) so it yields, and the first sweep now starts after
  /// the window has painted rather than while it is trying to.
  ///
  /// **What a session started in the gap gets, exactly.** The hook *entry* in
  /// the agent's own config is a constant written once and then recognised on
  /// every later launch (see `AgentHookInstaller.hookCommand`), so on any
  /// launch but the very first it is already there before this app starts. What
  /// a launch writes is the **endpoint file**, and the installed script reads
  /// that *when a hook fires* rather than when the CLI starts — so a session
  /// launched in the gap loses only the events that fire inside it, and starts
  /// reporting the moment the file lands. It is not a session that is deaf for
  /// its lifetime. That is exactly why the gap is one frame and not "when the
  /// app is idle", and why the caller's gate must have a fallback rather than
  /// waiting for a frame that a tray-only launch may never paint.
  ///
  /// Until the sweep reports, the app says so rather than saying nothing:
  /// `AgentHookInstallationReport.unswept` is the initial state and the Tools
  /// panel renders it as *not in place yet*. §19 of `CLAUDE.md` is the rule
  /// being followed — an unobserved state is `unknown`, never `healthy`.
  void installAgentHooks(
    LauncherControlServer server, {
    Future<void> Function()? afterFirstFrame,
  }) {
    // The WSL switch usually does not exist yet when an app that launches with
    // Windows starts, so the first sweep skips every WSL store — and until now
    // nothing ever revisited that decision: the owner's WSL sessions ran all
    // morning with no hooks while the adapter sat there. The server tells us
    // when it finally binds, and the sweep is idempotent to the byte, so
    // running it again costs a config rewrite only where something changed.
    //
    // No frame gate on this one: by the time the switch binds the window has
    // long since painted, and a re-sweep that waited for a *further* frame
    // would be waiting on an idle app.
    server.onWslInterfaceBound = () {
      _logger.info('The WSL switch is up; installing hooks for it now.');
      _installAgentHooksNow(server);
    };
    _installAgentHooksNow(server, gate: afterFirstFrame);
  }

  /// The one CLI-session import of this run, behind [afterFirstFrame].
  ///
  /// Same gate and same reasoning as [installAgentHooks]: the walk is over
  /// stores that live inside WSL, so every entry is a `\\wsl.localhost` round
  /// trip, and start-up is already under scrutiny. Nothing waits on it — the
  /// tree fills in when it lands, and until then the Explorer says the stores
  /// have not been checked rather than implying they have.
  ///
  /// A gate that throws must not cost the user their sessions, so it is caught
  /// and the import runs anyway; a launch straight to the tray may never paint
  /// a frame, which is what the caller's timeout is for.
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
    LauncherControlServer server, {
    Future<void> Function()? gate,
  }) {
    final endpoint = server.hookEndpoint;
    if (endpoint == null) return;
    _hookInstallation = _sweepAgentHooks(endpoint, gate);
  }

  /// One sweep, behind [gate], with everything it reports published.
  ///
  /// Retained by [_installAgentHooksNow] rather than fired and forgotten, so
  /// shutdown's `agent hook installation` step can wait for a config rewrite
  /// instead of cutting it off — and so a sweep still sitting behind [gate]
  /// when the user quits is one the shutdown budget can decline to wait for.
  Future<void> _sweepAgentHooks(
    AgentHookEndpoint endpoint,
    Future<void> Function()? gate,
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
    try {
      final results = await _container
          .read(agentHookInstallationServiceProvider)
          .installAll(endpoint);
      final report = AgentHookInstallationReport(results);
      // Published, not just logged. A skipped environment means the
      // hook-only states are unreportable there for the whole run, and
      // Settings is where the user can be told rather than told nothing.
      _container.read(agentHookInstallationReportProvider.notifier).set(report);
      // The environments that report by file rather than by socket. A
      // WSL agent cannot reach any address this app binds, so it writes
      // its payloads into its own store home and this polls for them;
      // see `AgentHookSpoolDrainer`. An empty list stops the timer, so a
      // machine with no WSL polls nothing.
      _container.read(agentHookSpoolDrainerProvider).watch(report.spoolSources);
      _logger.info(
        'Agent hooks: ${report.installed} installed, '
        '${results.length - report.installed - report.unknown} skipped'
        '${report.unknown == 0 ? '' : ', ${report.unknown} unknown'}'
        '${report.spoolSources.isEmpty ? '' : ', '
              '${report.spoolSources.length} reporting by spool'}.',
      );
    } on Object catch (error, stack) {
      _logger.warning('Agent hook installation failed.', error, stack);
    }
  }

  /// Installs Karmashala's skills into every agent CLI that declares a root,
  /// behind the same first-frame gate the hooks use.
  ///
  /// Beside the hooks because it is the same act — writing files into somebody
  /// else's agent configuration — and unlike them in every way that made hooks
  /// hard. There is no address, so no environment is skipped and none has to be
  /// probed; the bytes are constant, so a re-install writes nothing; and each
  /// `SKILL.md` is staged and renamed, so a sweep cut off by a quit leaves the
  /// old file or the new one and never half of either. That is why nothing
  /// waits for this at shutdown and nothing is retired there.
  ///
  /// Not retained and not awaited: a launch must not wait on a
  /// `\\wsl.localhost` share to answer, and the sweep publishes what it found
  /// when it lands.
  void installAgentSkills({Future<void> Function()? afterFirstFrame}) {
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

  /// Verifies the stored agent executables and repairs the rows whose path has
  /// rotted, behind [afterFirstFrame].
  ///
  /// **The owner's ask, and the durable half of the fix.** Codex's self-update
  /// turned the stable path the app had stored into a junction chain Windows
  /// refuses to traverse, and nothing ever looked again — the app kept trying
  /// to spawn a path that could not be spawned, launch after launch. The path
  /// is durable *state*; whether it still resolves is a *measurement*, and one
  /// taken at first run expires. So it is taken again on every launch.
  ///
  /// A repair also has to keep happening because its own answer is perishable:
  /// what the resolver finds is `releases\<version>\…`, which the next Codex
  /// update moves. The check is the part that lasts; the resolution is only
  /// what makes each round of it succeed.
  ///
  /// Same gate and same reasoning as [importCliSessions] — a stat is cheap but
  /// the sweep behind a failure is not, and the window must not wait on it. A
  /// gate that throws still gets the check run, because the gate is about
  /// *when*.
  ///
  /// Skipped on a workspace that has never discovered anything, exactly as
  /// [startAgentDiscovery] is: that launch's own first-run scan is writing the
  /// rows this would be checking, and racing it would probe everything twice.
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
      // Published, not just logged: an unrepaired row is something only the
      // user can fix, and Settings is where they can be told which of "not
      // installed" and "cannot be reached" it actually is.
      _container.read(agentPathRepairProvider.notifier).set(report);
      if (report.isClean) return;
      _logger.info('Agent paths: ${report.summary}');
    } on Object catch (error, stack) {
      // A check that could not run leaves the rows exactly as they were, which
      // is the same state the app was in before this existed.
      _logger.warning('Checking the stored agent paths failed.', error, stack);
    }
  }

  /// Re-reads the recorded agent versions whose reading has aged out, behind
  /// [afterFirstFrame] and **after** the path check.
  ///
  /// The other half of §20's problem, and the answer to the question §20 left
  /// open: a stored *path* was being re-measured on every launch while the
  /// stored *version* beside it was never re-read at all. `discoverUnprobed`
  /// skips any pair that already has an installation row, so a known agent's
  /// version was written once by the first scan and only a manual "Detect
  /// agents" ever wrote it again — the app reported Claude Code 2.1.252 for a
  /// binary answering 2.1.263, launch after launch.
  ///
  /// **The launch is the occasion; the row's recorded age is the gate.** A
  /// version probe is a subprocess, so re-reading unconditionally would spend
  /// exactly what makes the path check affordable, and re-reading per session
  /// start would spend a process per session for a number nobody is looking at.
  /// A workspace whose readings are all fresh spawns nothing here; one that has
  /// aged out pays one process per local and WSL installation, once, and not
  /// again until the reading ages out. What no cadence can fix is a bare
  /// number, so the reading's age is stored and shown — that is the durable
  /// half, exactly as the *check* rather than the resolution is the durable
  /// half of the path repair.
  ///
  /// After the path check, deliberately: a row the repair just moved has had
  /// its version re-read by that sweep already, and a row whose executable is
  /// gone must not be spawned at. It re-enters [repairAgentPaths], which is
  /// memoised, so the two share one gate and one run.
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

  /// The one conversation-index catch-up this database will ever have.
  ///
  /// **Once ever, not once a launch.** `ConversationIndexBackfill` records in
  /// `app_metadata` that it ran, and a workspace already caught up costs one
  /// metadata read here and stops. Everything after that arrives on the two
  /// triggers the index is built on — see `ConversationIndexer`.
  ///
  /// Sequenced *behind* [importCliSessions] rather than beside it, because both
  /// want a walk of the CLI stores and those live inside WSL: two of them
  /// racing is every entry paid for twice over `\\wsl.localhost`. The import
  /// also writes the `imported_sessions` rows this reads its paths from, so
  /// running second is what lets a first-ever launch index its history at all.
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

    // 0. Give up on any skill sweep still running. **Not a step**: it sets a
    //    flag and returns, so it needs no slice of the budget and cannot be
    //    abandoned itself. A sweep is bounded work whose *wait* something else
    //    already owns; what it must not do is go on writing into somebody's
    //    home after the app has gone, and telling it so is free.
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

    // 1b. Retire the callback endpoint (Loop 68, B2; narrowed in Loop 71).
    //     What dies with this process is the port and the token, and those now
    //     live in one generated file per agent rather than inline in the
    //     agent's own config — so this deletes those files and leaves the
    //     config entries alone. Taking the entries out here and putting
    //     byte-identical ones back on the next start is what gave the race in
    //     `AgentHookInstaller` two chances a launch to strip us out of somebody
    //     else's settings.json. With the endpoint file gone the installed
    //     script costs the agent an `if not exist` and exits zero, which is
    //     cheaper than the `curl -m 2` a stale entry used to cost.
    await _step('agent hook endpoint retirement', watch, () async {
      // Stop draining first. `retireEndpoints` deletes the spool directories,
      // and a tick that ran into a directory being removed underneath it would
      // do no harm but would spend the shutdown budget finding that out.
      if (_container.exists(agentHookSpoolDrainerProvider)) {
        _container.read(agentHookSpoolDrainerProvider).dispose();
      }
      await _container
          .read(agentHookInstallationServiceProvider)
          .retireEndpoints();
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

    // 7. The database handle, after everything that could still write through
    //    it has stopped. Not a `_step`: `close()` is one synchronous call that
    //    a deadline could not preempt anyway, and skipping it is what the soak
    //    was measuring. `exit(0)` releases the file but gives SQLite no chance
    //    to checkpoint, so every one of 20 quits left `karmashala.sqlite-wal`
    //    and `-shm` for the next launch to recover from.
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

  /// Puts what has been logged on disk, **outside [kShutdownBudget]**.
  ///
  /// It used to be a step like any other, and that was the bug: `_step` bounds
  /// every action by what is left of the shared deadline, so a shutdown that
  /// spent its budget skipped exactly the flush that would have recorded it.
  /// The soak counted the result — 20 quits, 8 `shutdown in N ms` lines — and
  /// the twelve missing ones are the twelve worth reading. A quit whose own
  /// account is the first casualty of the quit going wrong is a quit nobody
  /// can debug.
  ///
  /// Called again by `SystemIntegrationService._quit` immediately before the
  /// process ends, because the window destroy logs after this returns. Two
  /// flushes cost one empty queue check; a missing one costs the evidence.
  Future<void> flushLog() async {
    try {
      await Diagnostics.instance.flushFile().timeout(kLogFlushBudget);
    } on Object {
      // A sink that cannot be written must not hold the app open. Nothing is
      // logged about it: there is nowhere left for that line to go.
    }
  }

  /// The database this container was given, or null when it has none.
  ///
  /// Read *before* `dispose()` for the same reason the teardowns are: a
  /// disposed container cannot be read from, and this is the one handle whose
  /// close has to outlast every provider that might still be using it.
  AppDatabase? _databaseOrNull() {
    try {
      return _container.read(databaseProvider);
    } on Object {
      // Companion mode and a few tools build a container with no database.
      return null;
    }
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
