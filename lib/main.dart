import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/karmashala_app.dart';
import 'src/app/companion/companion_bootstrap.dart';
import 'src/app/companion/companion_mode.dart';
import 'src/core/database/app_database.dart';
import 'src/core/database/database_providers.dart';
import 'src/core/lifecycle/app_lifecycle.dart';
import 'src/core/logging/app_logger.dart';
import 'src/core/logging/diagnostics.dart';
import 'src/core/logging/diagnostics_bootstrap.dart';
import 'src/core/process/local_command_runner.dart';
import 'src/core/util/clock.dart';
import 'src/features/agents/application/agent_installations_controller.dart';
import 'src/features/environments/application/local_environment_bootstrap.dart';
import 'src/features/environments/data/environment_discovery_service.dart';
import 'src/features/environments/data/execution_environment_dao.dart';
import 'src/features/settings/application/settings_controller.dart';
import 'src/features/system/system_integration_service.dart';

/// Application entry point.
///
/// Bootstraps cross-cutting infrastructure (logging, database) before running
/// the app, then injects the opened database into the provider graph via a
/// `ProviderScope` override so features depend on providers, not globals.
Future<void> main() async {
  // A companion build (`--dart-define=KARMASHALA_MODE=companion`) boots its
  // own shell and nothing below this line — no PTYs, no discovery, no control
  // server, no tray, no window chrome.
  if (CompanionMode.enabled) return runCompanionApp();

  WidgetsFlutterBinding.ensureInitialized();
  // A desktop bootstrap on a phone is a build mistake, and it used to be a
  // *silent* one: `flutter build apk` without
  // `--dart-define=KARMASHALA_MODE=companion` produced an APK that installed,
  // launched, failed to load libmpv — which ships only for Windows here — and
  // then sat on a black screen with nothing in the log but the media_kit
  // complaint. Nothing below this line makes sense on a phone anyway: PTYs, a
  // control server, a tray icon, window chrome.
  if (Platform.isAndroid || Platform.isIOS) {
    throw StateError(
      'This is the desktop build running on a phone. Build the companion with '
      '--dart-define=KARMASHALA_MODE=companion.',
    );
  }
  // Loads libmpv, which decodes the device pane's H.264 live view.
  MediaKit.ensureInitialized();
  AppLogger.initialize();
  final logger = AppLogger.named('bootstrap');

  logger.info('Starting Karmashala.');
  // Opening the file needs `path_provider`, which is hundreds of milliseconds
  // into the launch — so it backfills the buffer rather than starting blank,
  // and the launch does not wait for it.
  // Awaited, not fired and forgotten: `AppDatabase.open()` on the next line
  // asks `path_provider` the same question, so this costs nothing, and it means
  // the file is open before anything interesting has had a chance to fail.
  await attachDefaultLogFile(Diagnostics.instance);
  final database = await AppDatabase.open();
  bootstrapMetadata(database, logger: logger);

  // Ensure the Windows environment exists immediately, then discover and persist
  // all execution environments (Windows host + installed WSL distributions),
  // best-effort — discovery degrades to Windows-only if WSL is unavailable.
  const clock = SystemClock();
  final environmentDao = ExecutionEnvironmentDao(database);
  ensureLocalEnvironment(environmentDao, clock);
  final discovered = await EnvironmentDiscoveryService(
    host: const LocalCommandRunner(),
    clock: clock,
    logger: logger,
  ).discover();
  for (final env in discovered) {
    environmentDao.upsert(env);
  }
  logger.info('Discovered ${discovered.length} execution environment(s).');

  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database)],
  );

  // The persisted diagnostics preferences: debug mode's root level, the buffer
  // bound, and whether the file is written at all.
  container.read(settingsControllerProvider.notifier).applyDiagnostics();

  // First run (or if it has never completed): probe every environment for
  // installed agents once, in the background so it doesn't delay window show.
  // The controller's state updates when it finishes, so the UI fills in live.
  if (database.readMetadata(MetadataKeys.agentsDiscoveredAt) == null) {
    unawaited(_discoverAgentsOnFirstRun(container, database, clock, logger));
  }

  // One owner for everything below, so quitting is an ordered teardown rather
  // than a process that happens to end. See `AppLifecycle`.
  final lifecycle = AppLifecycle(container, logger: logger);

  // An already-discovered workspace still has to notice agents it has never
  // looked for — the ones an app upgrade added to the registry after the
  // one-time scan above had already run.
  lifecycle.startAgentDiscovery();

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
        title: 'Karmashala',
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
    //
    // The lifecycle owner keeps the instance — it owns `/agent-hook`'s
    // ephemeral port and token, which the agents' installed hooks have to be
    // told about, and its `stop()` is what removes the handshake on the way
    // out. Nothing installed the hooks before Loop 31: `AgentHookInstaller` had
    // no call site since Loop 28, so `awaitingApproval` and `failed`, which
    // only a hook can observe, were unreachable in the running app.
    final controlServer = await lifecycle.startControlServer();
    if (controlServer != null) lifecycle.installAgentHooks(controlServer);
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const KarmashalaApp(),
    ),
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
    final found = await container
        .read(agentInstallationsControllerProvider.notifier)
        .discoverAll();
    database.writeMetadata(
      MetadataKeys.agentsDiscoveredAt,
      clock.nowUtc().toIso8601String(),
    );
    logger.info('First-run agent discovery found ${found.length} agent(s).');
  } catch (error, stack) {
    logger.warning(
      'First-run agent discovery failed; will retry next launch.',
      error,
      stack,
    );
  }
}
