import 'dart:async';
import 'dart:io';

import 'package:agent_cli/discovery.dart' hide Clock, SystemClock;
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_remote/client.dart' show CompanionPairing;
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;
import 'package:karmashala_terminal_runtime/persistence.dart'
    show TerminalLayoutStore;
import 'package:karmashala_ui/picking.dart';
import 'package:path/path.dart' as p;

import '../../features/agents/application/agent_installations_controller.dart';
import '../../features/devices/application/device_bindings.dart';
import '../../features/environments/application/browse_sources.dart';
import '../../features/environments/data/environments_data.dart';
import '../../features/explorer/application/session_list_snapshot.dart';
import '../../features/remote/application/machines_providers.dart';
import '../../features/sessions/application/session_engine_provider.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/local_host_providers.dart';
import '../../features/terminal/application/terminal_layout_providers.dart';
import '../capabilities/capabilities.dart';
import '../data/app_preferences.dart';
import '../data/data_client.dart';
import '../data/data_providers.dart';
import '../data/metadata_keys.dart';
import '../data/server_data_connection.dart';
import '../probe/probe_mode.dart';
import '../server/machines.dart';
import '../server/remote_server_access.dart';
import '../util/agent_cli_bridge.dart';
import 'app_lifecycle.dart';

/// The session [ServerSession.open] last opened and has not closed yet: what
/// the process-wide statics ([installServerSessionStatics]) read on each
/// call, so none of them keeps a container alive past its server.
ServerSession? get currentServerSession => _current;
ServerSession? _current;

/// **Everything this window holds for the one server it is a client of**
/// (plan step 13): the layout store, the access, the data connection, the
/// provider container with every override that names the server, the data
/// link's supervision, the remote scout, and the per-server start-up acts.
/// One [open], one [close]; what outlives a server — the window, the tray,
/// logging, the machines store — is the process's, and is not in here.
///
/// A switch of server closes one and opens the next in the same process
/// (`ServerSwitcher`, plan step 14); a quit closes the last.
class ServerSession {
  ServerSession._({
    required this.container,
    required this._logger,
    this._data,
    this._layoutStore,
    this._access,
    this._remoteAccess,
    this._undoSupervision,
  });

  /// A session over a [container] built elsewhere — a test's. It owns only
  /// what the container holds: [close] ends the session engine, the data
  /// client and the layout store if the container has them.
  ServerSession.ofContainer(this.container, {AppLogger? logger})
    : _logger = logger ?? AppLogger.named('server_session'),
      _data = null,
      _layoutStore = null,
      _access = null,
      _remoteAccess = null,
      _undoSupervision = null;

  /// Opens the session for [remote], or for this machine's own server when
  /// null. Builds, in order: the layout store (one per server), the access,
  /// the data connection, the container, then the per-server start-up acts
  /// that must run before the first frame. Becomes [currentServerSession].
  ///
  /// What it built is released again if a later part throws. [overrides] are
  /// the process's objects every session's container is handed — the
  /// switcher that replaces it (plan step 14). A [client] that cannot host a
  /// server has no session of its own: a null [remote] throws there.
  static Future<ServerSession> open({
    required CompanionPairing? remote,
    required Machines machines,
    required ProbeMode probe,
    required Directory support,
    required AppLogger logger,
    required ClientCapabilities client,
    List<Override> overrides = const [],
  }) async {
    if (remote == null && !client.hostsServer) {
      throw StateError(
        'This device runs no Karmashala server; pair a machine.',
      );
    }
    TerminalLayoutStore? layoutStore;
    SessionListSnapshotStore? snapshots;
    RemoteServerAccess? remoteAccess;
    DataClient? data;
    ProviderContainer? container;
    try {
      // The app opens no database: everything but the terminal layout is the
      // server's (docs/daemon-architecture.md, slice 1). The layout is this
      // window's own, beside the app — one per server, since a pane names a
      // session on the server it was opened on.
      final machineDirectory = remote == null
          ? support
          : await Directory(
              p.join(support.path, 'machines', remote.hostId.value),
            ).create(recursive: true);
      layoutStore = TerminalLayoutStore.open(machineDirectory);
      // A server elsewhere may not answer: its last session list is drawn
      // stale until it does (decision 9).
      if (remote != null) {
        snapshots = await SessionListSnapshotStore.open(
          machineDirectory,
          logger: logger,
        );
      }

      // Notes, todos and preferences live at the server, started here (or
      // adopted) or dialled elsewhere before anything reads a setting. One
      // that does not come up leaves the app saying so — it never keeps them
      // itself.
      final hostAccess = remote == null
          ? localHostSessionAccessFor(probe)
          : null;
      remoteAccess = remote == null
          ? null
          : RemoteServerAccess(
              hostId: remote.hostId.value,
              hostName: remote.hostName,
              store: machines.store,
            );
      data = remoteAccess == null
          ? await connectLocalServerData(
              access: hostAccess,
              hostsServer: client.hostsServer,
              logger: logger,
            )
          : await connectRemoteServerData(
              access: remoteAccess,
              logger: logger,
              // With a list to show, a slow dial goes on behind it.
              firstDialWithin: snapshots?.loaded == null
                  ? null
                  : kStaleListFirstDialWait,
            );
      final openedSnapshots = snapshots;
      container = ProviderContainer(
        overrides: [
          clientCapabilitiesProvider.overrideWithValue(client),
          terminalLayoutStoreProvider.overrideWithValue(layoutStore),
          dataClientProvider.overrideWithValue(data),
          localHostSessionAccessProvider.overrideWithValue(hostAccess),
          if (remoteAccess != null)
            serverAccessProvider.overrideWithValue(remoteAccess),
          if (openedSnapshots != null)
            sessionListSnapshotStoreProvider.overrideWith((ref) {
              ref.onDispose(openedSnapshots.dispose);
              return openedSnapshots;
            }),
          machinesProvider.overrideWithValue(machines),
          activeMachineProvider.overrideWithValue(remote),
          probeModeProvider.overrideWithValue(probe),
          // What `karmashala_devices` cannot know: this app's clock, its
          // SSH-aware runner factory, where it keeps data, its settings and
          // its shell.
          ...deviceBindings,
          ...overrides,
        ],
      );
      // Built now, so the container's disposal is what releases it.
      container.read(sessionListSnapshotStoreProvider);

      final undoSupervision = await _startServerActs(
        container,
        data,
        remote,
        logger,
      );
      return _current = ServerSession._(
        container: container,
        logger: logger,
        data: data,
        layoutStore: layoutStore,
        access: remoteAccess ?? hostAccess,
        remoteAccess: remoteAccess,
        undoSupervision: undoSupervision,
      );
    } catch (_) {
      // Nothing half-open outlives a failed open: the scout stops, the data
      // link closes, the layout database is released.
      try {
        container?.dispose();
      } on Object {
        // As below: the open's own failure is the one worth reporting.
      }
      snapshots?.dispose();
      if (data != null) unawaited(data.close().catchError((Object _) {}));
      if (remoteAccess != null) {
        unawaited(remoteAccess.close().catchError((Object _) {}));
      }
      try {
        layoutStore?.close();
      } on Object {
        // The open's own failure is the one worth reporting.
      }
      rethrow;
    }
  }

  /// The container every widget and provider of this server reads.
  final ProviderContainer container;

  final AppLogger _logger;
  final DataClient? _data;
  final TerminalLayoutStore? _layoutStore;

  /// What the shared host link is keyed by: the remote access, or this
  /// machine's own. Null when no server may be reached here.
  final HostSessionAccess? _access;
  final RemoteServerAccess? _remoteAccess;
  final void Function()? _undoSupervision;

  Future<bool>? _closing;

  /// Whether [close] has been started.
  bool get isClosing => _closing != null;

  /// Releases everything this session holds, in this order:
  ///
  /// 1. the data link's supervision (so a closing link is not "lost");
  /// 2. the teardowns disposing the container would otherwise fire and
  ///    forget — the session engine's agents and the data client — started;
  /// 3. the container, disposed;
  /// 4. those teardowns awaited, then the shared host link hung up and the
  ///    remote scout stopped — all of step 4 within [teardownBudget];
  /// 5. the layout store, the app's only database, **last**, whatever step 4
  ///    did: an unclosed one leaves a `-wal`/`-shm` for the next launch.
  ///
  /// A [teardownBudget] of zero or less waits for nothing, but still disposes
  /// and closes. Returns false when step 4 ran out of time. Idempotent.
  Future<bool> close({Duration teardownBudget = const Duration(seconds: 2)}) =>
      _closing ??= _close(teardownBudget);

  Future<bool> _close(Duration teardownBudget) async {
    if (identical(_current, this)) _current = null;

    try {
      _undoSupervision?.call();
    } on Object catch (error) {
      _logger.warning('server session: ending supervision failed: $error');
    }

    final pending = _startContainerTeardowns();
    final layoutStore =
        _layoutStore ??
        (container.exists(terminalLayoutStoreProvider)
            ? container.read(terminalLayoutStoreProvider)
            : null);
    try {
      container.dispose();
    } on Object catch (error, stack) {
      _logger.warning('Disposing the provider container failed.', error, stack);
    }

    // Once the data and the agents have let go of it, the link itself — and
    // with the link, the reason to keep listening for the server's beacon.
    Future<void> release() async {
      try {
        await Future.wait(pending);
      } on Object catch (error, stack) {
        _logger.warning('lifecycle: provider teardown failed.', error, stack);
      }
      final access = _access;
      if (access != null) {
        try {
          await SharedHostLinks.drop(access);
        } on Object catch (error) {
          _logger.warning('server session: hanging up the link failed: $error');
        }
      }
      try {
        await _remoteAccess?.close();
      } on Object catch (error) {
        _logger.warning('server session: stopping the scout failed: $error');
      }
    }

    var finished = true;
    final released = release();
    if (teardownBudget > Duration.zero) {
      try {
        await released.timeout(teardownBudget);
      } on TimeoutException {
        finished = false;
      }
    } else {
      finished = false;
    }

    try {
      layoutStore?.close();
    } on Object catch (error) {
      _logger.warning(
        'lifecycle: closing the layout store failed reason=$error',
      );
    }
    return finished;
  }

  /// Starts the teardowns that container disposal would otherwise fire and
  /// forget. Read and started before `dispose()`, so its own hooks are no-ops.
  List<Future<void>> _startContainerTeardowns() {
    final data =
        _data ??
        (container.exists(dataClientProvider)
            ? container.read(dataClientProvider)
            : null);
    final pending = <Future<void>>[];
    for (final start in <Future<void> Function()>[
      () => container.exists(sessionEngineProvider)
          ? container.read(sessionEngineProvider).dispose()
          : Future<void>.value(),
      () => data?.close() ?? Future<void>.value(),
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

  /// The per-server acts once the window is up, each once per session: this
  /// machine's session host, the agents' hooks and skills, the CLI-session
  /// import and the agent-path check. Every one belongs to a server that runs
  /// here; a client of a server elsewhere touches none of them (slice 5e).
  void startAfterRunApp(
    AppLifecycle lifecycle, {
    required Future<void> Function() afterFirstFrame,
  }) {
    final capabilities = container.read(capabilitiesProvider);
    // This machine's session host, now rather than on the first host-backed
    // pane: it owns the agents' hook endpoint and the lifecycle feed, so the
    // first session's first turn is heard only if it is already up. Started
    // after `runApp` so it never delays the window; the hook sweep below and
    // the lifecycle subscriber both wait for it.
    if (capabilities.setsUpThisMachine) lifecycle.startLocalHost();

    // The agents' status hooks, pointed at the server's hook endpoint: agents'
    // tools and hooks are the server's (slice 5b), and this app serves
    // neither.
    if (capabilities.setsUpThisMachine && capabilities.systemIntegration) {
      lifecycle.installAgentHooks(afterFirstFrame: afterFirstFrame);
    }

    // The skills, beside the hooks because it is the same act: a skill needs
    // no address, and its bytes are constant.
    if (capabilities.setsUpThisMachine) {
      lifecycle.installAgentSkills(afterFirstFrame: afterFirstFrame);
    }

    // The CLI stores, **once**, behind the same gate. The project row's
    // "Refresh CLI sessions" is what re-runs it.
    if (capabilities.setsUpThisMachine) {
      unawaited(lifecycle.importCliSessions(afterFirstFrame: afterFirstFrame));
    }

    // The stored agent executables: a path is durable state, whether it
    // resolves is a measurement, and Codex's self-update rots it.
    if (capabilities.setsUpThisMachine) {
      unawaited(lifecycle.repairAgentPaths(afterFirstFrame: afterFirstFrame));
    }
  }
}

/// The per-server acts before the first frame: the server's metadata, this
/// machine's environments recorded at it, the data link's supervision, the
/// diagnostics preferences and a first-run agent discovery. Returns what
/// undoes the supervision, if any was started.
Future<void Function()?> _startServerActs(
  ProviderContainer container,
  DataClient data,
  CompanionPairing? remote,
  AppLogger logger,
) async {
  // Read once for the start-up acts below; each is done once per session.
  final capabilities = container.read(capabilitiesProvider);
  final preferences = AppPreferences(data);
  // Only what the server said: an unread copy is not a first run.
  final preferencesRead = data.preferences.isPrimed;
  if (preferencesRead) bootstrapMetadata(preferences, logger: logger);

  // Discover every execution environment — this machine and its WSL
  // distributions (degrades to this machine alone without WSL) — and record
  // them at the server, which already has this machine's row from its own
  // start. Not awaited: a server that is not up yet takes them when it is.
  const clock = SystemClock();
  // This machine's environments are the server's only when it runs here: a
  // server elsewhere finds its own.
  if (capabilities.setsUpThisMachine) {
    final discovered = await EnvironmentDiscoveryService(
      host: const LocalCommandRunner(),
      // The app keeps one clock; the package carries its own copy of the type
      // so it can be published with no local dependency (agent_cli_bridge.dart).
      clock: agentCliClock(clock),
    ).discover();
    final environments = EnvironmentsData(data);
    for (final env in discovered) {
      unawaited(
        environments
            .put(env)
            .then<void>(
              (_) {},
              onError: (Object error) => logger.warning(
                'Could not record the environment ${env.id}: $error',
              ),
            ),
      );
    }
    logger.info('Discovered ${discovered.length} execution environment(s).');
  } else {
    logger.info('A client of the server on ${remote!.hostName}.');
  }

  // The supervisor keeps the server up; the data link follows it back.
  final supervisor = container.read(localHostSupervisorProvider);
  final undoSupervision = supervisor == null
      ? null
      : superviseDataLink(data, supervisor);

  // The persisted diagnostics preferences: debug mode's root level, the buffer
  // bound, and whether the file is written at all.
  container.read(settingsControllerProvider.notifier).applyDiagnostics();

  // First run, or one that never completed: probe every environment once, in
  // the background. The controller's state updates when it finishes.
  if (capabilities.setsUpThisMachine &&
      preferencesRead &&
      preferences.read(MetadataKeys.agentsDiscoveredAt) == null) {
    unawaited(_discoverAgentsOnFirstRun(container, preferences, clock, logger));
  }
  return undoSupervision;
}

/// Runs the one-time startup agent discovery. On success it stamps
/// [MetadataKeys.agentsDiscoveredAt] so it never repeats; on failure it leaves
/// the flag unset so the next launch retries.
Future<void> _discoverAgentsOnFirstRun(
  ProviderContainer container,
  AppPreferences preferences,
  Clock clock,
  AppLogger logger,
) async {
  try {
    final report = await container
        .read(agentInstallationsControllerProvider.notifier)
        .discoverAll();
    preferences.write(
      MetadataKeys.agentsDiscoveredAt,
      clock.nowUtc().toIso8601String(),
    );
    // The whole sentence, not just the hit count: "found 3 agent(s)" hid a
    // Windows probe that came back empty and would never be repeated.
    logger.info('First-run agent discovery: ${report.summary}');
  } catch (error, stack) {
    logger.warning(
      'First-run agent discovery failed; will retry next launch.',
      error,
      stack,
    );
  }
}

/// The container of [currentServerSession]. Throws while none is open, which
/// every static below already answers with its own default.
ProviderContainer _currentContainer() {
  final session = currentServerSession;
  if (session == null) throw StateError('No server session is open.');
  return session.container;
}

/// Installs, once per process, the statics `karmashala_ui` reads because it
/// cannot depend on Riverpod. Each reads the **current** session on every
/// call, never a captured container, so a switch of server (step 14) is
/// followed without reinstalling and no old container is kept alive.
void installServerSessionStatics() {
  // Every "Browse…" can look at a distribution or a host, not just this
  // computer. Read on each open, so an environment discovered later is
  // offered without restarting.
  BrowseSources.lookup = () => browseSourcesFrom(_currentContainer());
  // And which dialog opens, when the user has an opinion. Read per call rather
  // than captured, so switching it takes effect on the next Browse.
  // A server elsewhere reads only its own disk: the in-app picker browses it,
  // where the OS dialog would offer this machine's files.
  FilePickerChoice.prefersInApp = () {
    final container = _currentContainer();
    return !container.read(capabilitiesProvider).readsServerDisk ||
        (container.read(settingsControllerProvider).useInAppFilePicker ??
            FilePickerChoice.platformDefault);
  };
  // A pick from this device's own files (spec decision 11) follows the same
  // setting, but is never forced to the server; and while the server is here,
  // it is today's pick exactly.
  FilePickerChoice.devicePrefersInApp = () =>
      _currentContainer().read(settingsControllerProvider).useInAppFilePicker ??
      FilePickerChoice.platformDefault;
  FilePickerChoice.serverOnThisDevice = () =>
      _currentContainer().read(capabilitiesProvider).readsServerDisk;
  // And one answer about hidden files for every browser, persisted.
  HiddenFilesPreference.read = () =>
      _currentContainer().read(settingsControllerProvider).showHiddenFiles;
  HiddenFilesPreference.write = (value) => _currentContainer()
      .read(settingsControllerProvider.notifier)
      .setShowHiddenFiles(value);
}
