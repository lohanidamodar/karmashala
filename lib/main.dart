import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app/chitragupta_app.dart';
import 'src/core/database/app_database.dart';
import 'src/core/database/database_providers.dart';
import 'src/core/logging/app_logger.dart';
import 'src/core/process/windows_command_runner.dart';
import 'src/core/util/clock.dart';
import 'src/features/agents/application/agent_installations_controller.dart';
import 'src/features/environments/application/local_environment_bootstrap.dart';
import 'src/features/environments/data/environment_discovery_service.dart';
import 'src/features/environments/data/execution_environment_dao.dart';
import 'src/features/mcp/launcher_control_server.dart';
import 'src/features/settings/application/settings_controller.dart';
import 'src/features/system/system_integration_service.dart';

/// Application entry point.
///
/// Bootstraps cross-cutting infrastructure (logging, database) before running
/// the app, then injects the opened database into the provider graph via a
/// `ProviderScope` override so features depend on providers, not globals.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Loads libmpv, which decodes the device pane's H.264 live view.
  MediaKit.ensureInitialized();
  AppLogger.initialize();
  final logger = AppLogger.named('bootstrap');

  logger.info('Starting Chitragupta.');
  final database = await AppDatabase.open();
  bootstrapMetadata(database, logger: logger);

  // Ensure the Windows environment exists immediately, then discover and persist
  // all execution environments (Windows host + installed WSL distributions),
  // best-effort — discovery degrades to Windows-only if WSL is unavailable.
  const clock = SystemClock();
  final environmentDao = ExecutionEnvironmentDao(database);
  ensureLocalEnvironment(environmentDao, clock);
  final discovered = await EnvironmentDiscoveryService(
    host: const WindowsCommandRunner(),
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

  // First run (or if it has never completed): probe every environment for
  // installed agents once, in the background so it doesn't delay window show.
  // The controller's state updates when it finishes, so the UI fills in live.
  if (database.readMetadata(MetadataKeys.agentsDiscoveredAt) == null) {
    unawaited(_discoverAgentsOnFirstRun(container, database, clock, logger));
  }

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
        title: 'Chitragupta',
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (error, stack) {
      logger.warning('Window manager init failed.', error, stack);
    }
    await SystemIntegrationService(container).init();

    // Local control server for the launcher agent's MCP bridge (best-effort).
    try {
      await LauncherControlServer(container, logger: logger).start();
    } catch (error, stack) {
      logger.warning('Launcher control server failed to start.', error, stack);
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ChitraguptaApp(),
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
