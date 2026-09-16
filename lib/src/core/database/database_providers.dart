import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_store/database.dart';

/// Provides the application [AppDatabase], created at bootstrap and supplied
/// by a `ProviderScope` override. Throws without one, so wiring fails loudly.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError(
    'databaseProvider must be overridden with an AppDatabase instance.',
  );
});

/// Metadata keys persisted in the [AppMetadata] table.
class MetadataKeys {
  const MetadataKeys._();

  static const schemaVersion = 'schema_version';
  static const firstRunAt = 'first_run_at';

  /// Set once the first automatic agent discovery has completed; absence
  /// triggers a one-time probe on startup.
  static const agentsDiscoveredAt = 'agents_discovered_at';
  static const environmentHealthOnboarding = 'environment_health_onboarding';

  /// Set once the conversation index has caught up with what the workspace
  /// already had, which makes the backfill a one-off rather than a sweep.
  static const conversationIndexBackfilledAt =
      'conversation_index_backfilled_at';
}

/// Records baseline application metadata on startup: the persisted schema
/// version and, on first ever run, a first-run timestamp.
MetadataBootstrap bootstrapMetadata(AppDatabase db, {AppLogger? logger}) {
  final existingFirstRun = db.readMetadata(MetadataKeys.firstRunAt);
  final isFirstRun = existingFirstRun == null;

  if (isFirstRun) {
    db.writeMetadata(
      MetadataKeys.firstRunAt,
      DateTime.now().toUtc().toIso8601String(),
    );
    db.writeMetadata(MetadataKeys.environmentHealthOnboarding, 'pending');
  }
  db.writeMetadata(MetadataKeys.schemaVersion, db.schemaVersion.toString());

  logger?.info(
    'Metadata bootstrap complete (firstRun=$isFirstRun, '
    'schemaVersion=${db.schemaVersion}).',
  );
  return MetadataBootstrap(
    isFirstRun: isFirstRun,
    schemaVersion: db.schemaVersion,
  );
}

/// Outcome of [bootstrapMetadata].
class MetadataBootstrap {
  const MetadataBootstrap({
    required this.isFirstRun,
    required this.schemaVersion,
  });

  final bool isFirstRun;
  final int schemaVersion;
}
