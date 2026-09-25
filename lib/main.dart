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
import 'package:karmashala_store/database.dart';
import 'src/core/database/database_providers.dart';
import 'src/core/lifecycle/app_binding.dart';
import 'src/core/lifecycle/app_lifecycle.dart';
import 'src/core/lifecycle/uncaught_errors.dart';
import 'package:karmashala_core/logging.dart';
import 'src/core/logging/diagnostics_bootstrap.dart';
import 'src/core/paths/app_support_directory.dart';
import 'src/core/probe/probe_mode.dart';
import 'src/core/util/agent_cli_bridge.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_ui/picking.dart';
import 'src/features/environments/application/browse_sources.dart';
import 'src/features/agents/application/agent_installations_controller.dart';
import 'src/features/devices/application/device_bindings.dart';
import 'src/features/environments/application/local_environment_bootstrap.dart';
import 'package:agent_cli/discovery.dart' hide Clock, SystemClock;
import 'src/features/env_secrets/application/env_secrets_controller.dart';
import 'src/features/env_secrets/data/env_vault.dart';
import 'src/features/environments/data/execution_environment_dao.dart';
import 'src/features/mcp/launcher_control_server.dart';
import 'src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'src/features/sessions/application/session_liveness_reconciler.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'src/features/settings/application/settings_controller.dart';
import 'src/features/system/system_integration_service.dart';
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
  // before the log file or the database is opened.
  final probe = ProbeMode.current;
  if (probe.enabled) {
    logger.info(
      'PROBE instance; data folder ${probe.dataDirectory ?? '(none)'}. '
      'Disabled: ${ProbeMode.disabledEffects.join(', ')}.',
    );
    await appSupportDirectory();
  }
  // Opening the file needs `path_provider`, hundreds of milliseconds in, so it
  // backfills the buffer. Awaited: the directory below asks the same question.
  await attachDefaultLogFile(Diagnostics.instance);
  // The app resolves the directory; `AppDatabase` only opens in it.
  final database = AppDatabase.open(await appSupportDirectory());
  bootstrapMetadata(database, logger: logger);

  // The verification artifact root, before the first frame: a Riverpod provider
  // that threw stays errored for the life of the process. Best-effort.
  try {
    await resolveVerificationRoot();
  } catch (error, stack) {
    logger.warning('Verification artifact root unavailable.', error, stack);
  }

  // Ensure the Windows environment exists, then discover and persist every
  // execution environment; degrades to Windows-only if WSL is unavailable.
  const clock = SystemClock();
  final environmentDao = ExecutionEnvironmentDao(database);
  ensureLocalEnvironment(environmentDao, clock);
  final discovered = await EnvironmentDiscoveryService(
    host: const LocalCommandRunner(),
    // The app keeps one clock; the package carries its own copy of the type so it
    // can be published with no local dependency (agent_cli_bridge.dart).
    clock: agentCliClock(clock),
  ).discover();
  for (final env in discovered) {
    environmentDao.upsert(env);
  }
  logger.info('Discovered ${discovered.length} execution environment(s).');

  // Awaited rather than fired off: `restoreLivePanes` can re-launch panes as
  // soon as the container exists, and one started early would lack its variables.
  final envVault = await EnvVault.open(logger: logger);
  await envVault.load();

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      envVaultProvider.overrideWithValue(envVault),
      probeModeProvider.overrideWithValue(probe),
      // What `karmashala_devices` cannot know: this app's clock, its SSH-aware
      // runner factory, where it keeps data, its settings and its shell.
      ...deviceBindings,
    ],
  );

  // Before any pane exists: a row still claiming to run from a previous run is
  // one we lost sight of — unless this machine's host feed will say otherwise.
  final followsLocalHost = container.read(hostLifecycleSourceProvider) != null;
  final onThisMachine = container.read(sessionRunsOnThisMachineProvider);
  final lost = markSessionsLostOnLaunch(
    SessionDao(database),
    where: followsLocalHost ? (session) => !onThisMachine(session) : null,
  );
  if (lost > 0) {
    logger.info('$lost session(s) were still marked live from a previous run.');
  }

  // The persisted diagnostics preferences: debug mode's root level, the buffer
  // bound, and whether the file is written at all.
  container.read(settingsControllerProvider.notifier).applyDiagnostics();

  // Built eagerly for one reason: constructing it installs the redaction rule
  // that keeps this session's secret values out of the log.
  container.read(envSecretsControllerProvider);

  // First run, or one that never completed: probe every environment once, in
  // the background. The controller's state updates when it finishes.
  if (database.readMetadata(MetadataKeys.agentsDiscoveredAt) == null) {
    unawaited(_discoverAgentsOnFirstRun(container, database, clock, logger));
  }

  // One owner for everything below, so quitting is an ordered teardown rather
  // than a process that happens to end. See `AppLifecycle`.
  final lifecycle = AppLifecycle(container, logger: logger);

  // An already-discovered workspace still has to notice agents it has never
  // looked for — the ones an app upgrade added after the one-time scan.
  lifecycle.startAgentDiscovery();

  // A release build has no VM service, so the log is the only place this app
  // can say what it is holding. Started here rather than after the first frame:
  // the interval is long enough that bootstrap is over before it first fires.
  lifecycle.startMemoryCensus();

  // Retained here so the hook sweep below can be started *after* `runApp` —
  // see the sweep's own comment for why that ordering is the point.
  LauncherControlServer? controlServer;

  // Desktop OS integration: window/tray/keep-awake/launch-at-login.
  if (SystemIntegrationService.isSupported) {
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

    // Local control server for the launcher agent's MCP bridge (best-effort).
    // The lifecycle owner keeps it: its `stop()` removes the handshake.
    controlServer = await lifecycle.startControlServer();
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KarmashalaApp(),
    ),
  );

  // The agents' status hooks, **after the first frame** rather than before the
  // window. The gate's timeout is load-bearing: a tray launch may never paint.
  Future<void> afterFirstFrame() => WidgetsBinding.instance.endOfFrame.timeout(
    const Duration(seconds: 2),
    onTimeout: () {},
  );

  if (controlServer != null) {
    lifecycle.installAgentHooks(
      controlServer,
      afterFirstFrame: afterFirstFrame,
    );
  }

  // The skills, beside the hooks because it is the same act. Not behind
  // `controlServer`: a skill needs no address, and its bytes are constant.
  lifecycle.installAgentSkills(afterFirstFrame: afterFirstFrame);

  // The CLI stores, **once**, behind the same gate. The project row's "Refresh
  // CLI sessions" is what re-runs it. Nothing here needs a bound server.
  unawaited(lifecycle.importCliSessions(afterFirstFrame: afterFirstFrame));

  // Every "Browse…" can now look at a distribution or a host, not just this
  // computer. Installed once, read on each open, so an environment discovered
  // later is offered without restarting.
  BrowseSources.lookup = () => browseSourcesFrom(container);
  // And which dialog opens, when the user has an opinion. Read per call rather
  // than captured, so switching it takes effect on the next Browse.
  FilePickerChoice.prefersInApp = () =>
      container.read(settingsControllerProvider).useInAppFilePicker ??
      FilePickerChoice.platformDefault;
  // And one answer about hidden files for every browser, persisted.
  HiddenFilesPreference.read = () =>
      container.read(settingsControllerProvider).showHiddenFiles;
  HiddenFilesPreference.write = (value) => container
      .read(settingsControllerProvider.notifier)
      .setShowHiddenFiles(value);

  // The stored agent executables, on every launch: a path is durable state,
  // whether it resolves is a measurement, and Codex's self-update rots it.
  unawaited(lifecycle.repairAgentPaths(afterFirstFrame: afterFirstFrame));

  // And what those executables *are*, when the last reading has aged out. Only
  // rows older than `kVersionReadingFreshFor`, so a fresh workspace spawns none.
  unawaited(lifecycle.refreshAgentVersions(afterFirstFrame: afterFirstFrame));

  // The one catch-up the conversation index will ever have — the history that
  // was on disk before either of its triggers could fire. Once per database.
  unawaited(
    lifecycle.backfillConversationIndex(afterFirstFrame: afterFirstFrame),
  );
}

/// Runs the one-time startup agent discovery. On success it stamps
/// [MetadataKeys.agentsDiscoveredAt] so it never repeats; on failure it leaves
/// the flag unset so the next launch retries.
Future<void> _discoverAgentsOnFirstRun(
  ProviderContainer container,
  AppDatabase database,
  Clock clock,
  AppLogger logger,
) async {
  try {
    final report = await container
        .read(agentInstallationsControllerProvider.notifier)
        .discoverAll();
    database.writeMetadata(
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
