import 'package:karmashala_core/logging.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;

/// The one-off stamps this app keeps among its preferences.
class MetadataKeys {
  const MetadataKeys._();

  static const firstRunAt = 'first_run_at';

  /// Set once the first automatic agent discovery has completed; absence
  /// triggers a one-time probe on startup.
  static const agentsDiscoveredAt = 'agents_discovered_at';
  static const environmentHealthOnboarding = 'environment_health_onboarding';
}

/// Stamps the first run, once. Answers whether this is it.
bool bootstrapMetadata(
  PreferenceStore preferences, {
  DateTime Function()? now,
  AppLogger? logger,
}) {
  final isFirstRun = preferences.read(MetadataKeys.firstRunAt) == null;
  if (isFirstRun) {
    preferences
      ..write(
        MetadataKeys.firstRunAt,
        (now?.call() ?? DateTime.now().toUtc()).toIso8601String(),
      )
      ..write(MetadataKeys.environmentHealthOnboarding, 'pending');
  }
  logger?.info('Metadata bootstrap complete (firstRun=$isFirstRun).');
  return isFirstRun;
}
