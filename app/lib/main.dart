import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/bootstrap_failure_app.dart';
import 'src/app/karmashala_app.dart';
import 'src/app/companion/companion_bootstrap.dart';
import 'src/app/companion/companion_mode.dart';
import 'src/core/capabilities/capabilities.dart';
import 'src/core/data/app_preferences.dart';
import 'src/core/data/data_providers.dart';
import 'src/core/data/metadata_keys.dart';
import 'src/core/data/server_data_connection.dart';
import 'src/core/lifecycle/app_binding.dart';
import 'src/core/lifecycle/app_lifecycle.dart';
import 'src/core/lifecycle/uncaught_errors.dart';
import 'package:karmashala_core/logging.dart';
import 'src/core/logging/diagnostics_bootstrap.dart';
import 'src/core/paths/app_support_directory.dart';
import 'src/core/paths/server_data_directory.dart';
import 'src/core/probe/probe_mode.dart';
import 'src/core/server/machines.dart';
import 'src/core/server/remote_server_access.dart';
import 'src/features/remote/application/machines_providers.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show SharedHostLinks;
import 'package:path/path.dart' as p;
import 'src/core/util/agent_cli_bridge.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_ui/picking.dart';
import 'src/features/environments/application/browse_sources.dart';
import 'src/features/agents/application/agent_installations_controller.dart';
import 'src/features/devices/application/device_bindings.dart';
import 'package:agent_cli/discovery.dart' hide Clock, SystemClock;
import 'src/features/environments/data/environments_data.dart';
import 'src/features/settings/application/settings_controller.dart';
import 'src/features/terminal/application/local_host_providers.dart';
import 'src/features/terminal/application/terminal_layout_providers.dart';
import 'package:karmashala_terminal_runtime/persistence.dart'
    show TerminalLayoutStore;
import 'src/features/verification/application/verification_providers.dart';

/// Application entry point. Logging and the uncaught-error handlers first, so
/// whatever the bootstrap does next is on record if it fails.
Future<void> main() async {
  // A companion build boots its own shell and nothing below this line — no
  // PTYs, no discovery, no control server, no tray, no window chrome.
  if (CompanionMode.enabled) return runCompanionApp();

  ensureAppBinding();
  // A desktop bootstrap on a phone is a build mistake, and it used to be a
  // silent one: an APK that installed, launched and sat on a black screen.
  if (Platform.isAndroid || Platform.isIOS) {
    throw StateError(
      'This is the desktop build running on a phone. Build the companion with '
      '--dart-define=KARMASHALA_MODE=companion.',
    );
  }
  AppLogger.initialize();
  final logger = AppLogger.named('bootstrap');
  UncaughtErrorHandlers(logger).install();

  try {
    await _bootstrap(logger);
  } catch (error, stack) {
    logger.error('Bootstrap failed.', error, stack);
    await Diagnostics.instance.flushFile();
    runApp(
      BootstrapFailureApp(
        error: error,
        stack: stack,
        logDirectory: await _logDirectoryOrNull(),
      ),
    );
  }
}

Future<Directory?> _logDirectoryOrNull() async {
  try {
    return await defaultLogDirectory();
  } catch (_) {
    return null;
  }
}

Future<void> _bootstrap(AppLogger logger) async {
  // Loads libmpv, which decodes the device pane's H.264 live view.
  MediaKit.ensureInitialized();

  // Which build, on what OS — first line of the buffer, so it is the first line
  // of anything copied out. A log that cannot say its version answers nothing.
  logger.info('Starting ${buildIdentity()}');
  // Read once and handed to the container below, so every side-effect site
  // asks one provider. A probe without its own data folder is refused here,
  // before the log file is opened.
  final probe = ProbeMode.current;
  if (probe.enabled) {
    logger.info(
      'PROBE instance; data folder ${probe.dataDirectory ?? '(none)'}. '
      'Disabled: ${ProbeMode.disabledEffects.join(', ')}.',
    );
    await appSupportDirectory();
    await serverDataDirectory();
  }
  // Opening the file needs `path_provider`, hundreds of milliseconds in, so it
  // backfills the buffer. Awaited: the directory below asks the same question.
  await attachDefaultLogFile(Diagnostics.instance);
  // Which server this window is a client of (slice 5e): this machine's own,
  // or one elsewhere chosen in Settings → Machines, only dialled.
  final support = await appSupportDirectory();
  final machines = Machines(MachinesFileStore.inDirectory(support.path));
  final remote = await machines.active();
  SharedHostLinks.clientName = _machineName();

  // The app opens no database: everything but the terminal layout is the
  // server's (docs/daemon-architecture.md, slice 1). The layout is this
  // window's own, beside the app — one per server, since a pane names a
  // session on the server it was opened on.
  final layoutStore = TerminalLayoutStore.open(
    remote == null
        ? support
        : (await Directory(
            p.join(support.path, 'machines', remote.hostId.value),
          ).create(recursive: true)),
  );

  // Notes, todos and preferences live at the server, started here (or
  // adopted) or dialled elsewhere before anything reads a setting. One that
  // does not come up leaves the app saying so — it never keeps them itself.
  final hostAccess = remote == null ? localHostSessionAccessFor(probe) : null;
  final remoteAccess = remote == null
      ? null
      : RemoteServerAccess(
          hostId: remote.hostId.value,
          hostName: remote.hostName,
          store: machines.store,
        );
  final data = remoteAccess == null
      ? await connectLocalServerData(access: hostAccess, logger: logger)
      : await connectRemoteServerData(access: remoteAccess, logger: logger);
  final container = ProviderContainer(
    overrides: [
      terminalLayoutStoreProvider.overrideWithValue(layoutStore),
      dataClientProvider.overrideWithValue(data),
      localHostSessionAccessProvider.overrideWithValue(hostAccess),
      if (remoteAccess != null)
        serverAccessProvider.overrideWithValue(remoteAccess),
      machinesProvider.overrideWithValue(machines),
      activeMachineProvider.overrideWithValue(remote),
      probeModeProvider.overrideWithValue(probe),
      // What `karmashala_devices` cannot know: this app's clock, its SSH-aware
      // runner factory, where it keeps data, its settings and its shell.
      ...deviceBindings,
    ],
  );
  // Read once for the start-up acts below; each is done once per launch.
  final capabilities = container.read(capabilitiesProvider);
  final preferences = AppPreferences(data);
  // Only what the server said: an unread copy is not a first run.
  final preferencesRead = data.preferences.isPrimed;
  if (preferencesRead) bootstrapMetadata(preferences, logger: logger);

  // The verification artifact root, before the first frame: a Riverpod provider
  // that threw stays errored for the life of the process. Best-effort.
  try {
    await resolveVerificationRoot();
  } catch (error, stack) {
    logger.warning('Verification artifact root unavailable.', error, stack);
  }

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
  if (supervisor != null) superviseDataLink(data, supervisor);

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

  // One owner for everything below, so quitting is an ordered teardown rather
  // than a process that happens to end. See `AppLifecycle`.
  final lifecycle = AppLifecycle(container, logger: logger);

  // A release build has no VM service, so the log is the only place this app
  // can say what it is holding. Started here rather than after the first frame:
  // the interval is long enough that bootstrap is over before it first fires.
  lifecycle.startMemoryCensus();

  // Desktop OS integration: window/tray/keep-awake/launch-at-login.
  if (capabilities.systemIntegration) {
    try {
      await windowManager.ensureInitialized();
      final settings = container.read(settingsControllerProvider);
      final restoredSize =
          (settings.windowWidth != null && settings.windowHeight != null)
          ? Size(settings.windowWidth!, settings.windowHeight!)
          : const Size(1200, 800);
      final windowOptions = WindowOptions(
        size: restoredSize,
        minimumSize: const Size(720, 560),
        center: true,
        title: probe.enabled ? 'Karmashala — PROBE' : 'Karmashala',
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (error, stack) {
      logger.warning('Window manager init failed.', error, stack);
    }
    await lifecycle.startSystemIntegration();
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KarmashalaApp(),
    ),
  );

  // This machine's session host, now rather than on the first host-backed pane:
  // it owns the agents' hook endpoint and the lifecycle feed, so the first
  // session's first turn is heard only if it is already up. Started after
  // `runApp` so it never delays the window; the hook sweep below and the
  // lifecycle subscriber both wait for it.
  if (capabilities.setsUpThisMachine) lifecycle.startLocalHost();

  // The agents' status hooks, **after the first frame** rather than before the
  // window. The gate's timeout is load-bearing: a tray launch may never paint.
  Future<void> afterFirstFrame() => WidgetsBinding.instance.endOfFrame.timeout(
    const Duration(seconds: 2),
    onTimeout: () {},
  );

  // Pointed at the server's hook endpoint: agents' tools and hooks are the
  // server's (slice 5b), and this app serves neither.
  // This machine's agents, hooks, skills and CLI stores belong to the server
  // that runs them — this machine's own. A client of a server elsewhere
  // touches none of them (slice 5e).
  if (capabilities.setsUpThisMachine && capabilities.systemIntegration) {
    lifecycle.installAgentHooks(afterFirstFrame: afterFirstFrame);
  }

  // The skills, beside the hooks because it is the same act: a skill needs no
  // address, and its bytes are constant.
  if (capabilities.setsUpThisMachine) {
    lifecycle.installAgentSkills(afterFirstFrame: afterFirstFrame);
  }

  // The CLI stores, **once**, behind the same gate. The project row's "Refresh
  // CLI sessions" is what re-runs it. Nothing here needs a bound server.
  if (capabilities.setsUpThisMachine) {
    unawaited(lifecycle.importCliSessions(afterFirstFrame: afterFirstFrame));
  }

  // Every "Browse…" can now look at a distribution or a host, not just this
  // computer. Installed once, read on each open, so an environment discovered
  // later is offered without restarting.
  BrowseSources.lookup = () => browseSourcesFrom(container);
  // And which dialog opens, when the user has an opinion. Read per call rather
  // than captured, so switching it takes effect on the next Browse.
  // A server elsewhere reads only its own disk: the in-app picker browses it,
  // where the OS dialog would offer this machine's files.
  FilePickerChoice.prefersInApp = () =>
      !container.read(capabilitiesProvider).readsServerDisk ||
      (container.read(settingsControllerProvider).useInAppFilePicker ??
          FilePickerChoice.platformDefault);
  // And one answer about hidden files for every browser, persisted.
  HiddenFilesPreference.read = () =>
      container.read(settingsControllerProvider).showHiddenFiles;
  HiddenFilesPreference.write = (value) => container
      .read(settingsControllerProvider.notifier)
      .setShowHiddenFiles(value);

  // The stored agent executables, on every launch: a path is durable state,
  // whether it resolves is a measurement, and Codex's self-update rots it.
  if (capabilities.setsUpThisMachine) {
    unawaited(lifecycle.repairAgentPaths(afterFirstFrame: afterFirstFrame));
  }
}

/// What this client is called at a server: the machine's name.
String _machineName() {
  final name = Platform.localHostname.trim();
  return name.isEmpty ? 'karmashala' : name;
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
