import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/app_logger.dart';
import 'app_database.dart';

/// Provides the application [AppDatabase].
///
/// The concrete instance is created during bootstrap and supplied via a
/// `ProviderScope` override (see `main.dart`). Tests override it with an
/// in-memory database. It deliberately throws if read without an override so a
/// missing wiring fails loudly rather than silently opening a stray database.
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

  /// Set once the first automatic agent discovery has completed successfully.
  /// Absence means discovery has never run, which triggers a one-time probe on
  /// startup (see `main.dart`).
  static const agentsDiscoveredAt = 'agents_discovered_at';
  static const environmentHealthOnboarding = 'environment_health_onboarding';

  /// Set once the conversation index has caught up with the conversations the
  /// workspace already had. Its presence is what makes the backfill a one-off
  /// rather than a sweep — see `ConversationIndexBackfill`.
  static const conversationIndexBackfilledAt =
      'conversation_index_backfilled_at';
}

/// Records baseline application metadata on startup.
///
/// Writes the persisted schema version and, on first ever run, a first-run
/// timestamp. Returns the bootstrap result for logging/inspection.
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
