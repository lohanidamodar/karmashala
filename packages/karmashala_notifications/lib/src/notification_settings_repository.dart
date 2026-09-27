import 'dart:convert';

import 'notification_settings.dart';

/// Persists [NotificationSettings] as a preference of its own at the server,
/// so it round-trips independently of the shared user settings record.
///
/// Takes the preference's read and write rather than a store type: this
/// package is a dependency of the data API, which carries its values, so it
/// may not depend on that API back.
class NotificationSettingsRepository {
  NotificationSettingsRepository({required this._read, required this._write});

  final String? Function(String key) _read;
  final void Function(String key, String value) _write;
  static const _key = 'notifications.v1';

  NotificationSettings load() {
    final raw = _read(_key);
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
      _write(_key, jsonEncode(settings.toJson()));
}
