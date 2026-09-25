import 'dart:convert';

import 'package:karmashala_store/database.dart';

import '../domain/companion_config.dart';

/// Where the session host keeps the last [CompanionConfig] an app sent, in the
/// shared store's `app_metadata`. Written only by the host; the app sends the
/// config over its link and never reads this.
const String kCompanionConfigMetadataKey = 'companion.host_config.v1';

/// The host's copy of the desktop's Remote access settings, kept so a host
/// started before the app — or serving after it closed — does what the person
/// last chose rather than a default.
class CompanionConfigStore {
  CompanionConfigStore(this._database);

  final AppDatabase _database;

  /// The kept config, or null when no app has sent one here. A value that
  /// will not read is treated as never written.
  CompanionConfig? read() {
    final raw = _database.readMetadata(kCompanionConfigMetadataKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, Object?>) return CompanionConfig.fromJson(json);
    } on FormatException {
      // Unreadable: the next app to connect writes a good one.
    }
    return null;
  }

  /// Keeps [config] without the app's embedded relay, which closes with it.
  void write(CompanionConfig config) => _database.writeMetadata(
    kCompanionConfigMetadataKey,
    jsonEncode(config.withoutLocalRelay().toJson()),
  );
}
