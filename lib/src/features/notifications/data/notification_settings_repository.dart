import 'dart:convert';

import 'package:karmashala_store/database.dart';
import '../domain/notification_settings.dart';

/// Persists [NotificationSettings] in the `app_metadata` table, under its own
/// key so it round-trips independently of the shared user settings record.
class NotificationSettingsRepository {
  NotificationSettingsRepository(this._db);

  final AppDatabase _db;
  static const _key = 'notifications.v1';

  NotificationSettings load() {
    final raw = _db.readMetadata(_key);
    if (raw == null) return const NotificationSettings();
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? NotificationSettings.fromJson(decoded)
          : const NotificationSettings();
    } on FormatException {
      return const NotificationSettings();
    }
  }

  void save(NotificationSettings settings) =>
      _db.writeMetadata(_key, jsonEncode(settings.toJson()));
}
