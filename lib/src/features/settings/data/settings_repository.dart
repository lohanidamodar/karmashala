import 'dart:convert';

import 'package:karmashala_store/database.dart';
import '../domain/settings.dart';

/// Persists [Settings] in the `app_metadata` key/value table (as JSON).
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;
  static const _key = 'settings.v1';

  Settings load() {
    final raw = _db.readMetadata(_key);
    if (raw == null) return const Settings();
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? Settings.fromJson(decoded)
          : const Settings();
    } on FormatException {
      return const Settings();
    }
  }

  void save(Settings settings) =>
      _db.writeMetadata(_key, jsonEncode(settings.toJson()));
}
