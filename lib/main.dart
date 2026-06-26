import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/chitragupta_app.dart';
import 'src/core/database/app_database.dart';
import 'src/core/database/database_providers.dart';
import 'src/core/logging/app_logger.dart';
import 'src/core/process/windows_command_runner.dart';
import 'src/core/util/clock.dart';
import 'src/features/environments/application/local_environment_bootstrap.dart';
import 'src/features/environments/data/environment_discovery_service.dart';
import 'src/features/environments/data/execution_environment_dao.dart';

/// Application entry point.
///
/// Bootstraps cross-cutting infrastructure (logging, database) before running
/// the app, then injects the opened database into the provider graph via a
/// `ProviderScope` override so features depend on providers, not globals.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(database)],
      child: const ChitraguptaApp(),
    ),
  );
}
