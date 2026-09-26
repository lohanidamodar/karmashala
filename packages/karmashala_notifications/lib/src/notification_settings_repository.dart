import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;
import 'notification_settings.dart';

/// Persists [NotificationSettings] as a preference of its own at the server,
/// so it round-trips independently of the shared user settings record.
class NotificationSettingsRepository {
  NotificationSettingsRepository(this._preferences);

  final PreferenceStore _preferences;
  static const _key = 'notifications.v1';

  NotificationSettings load() {
    final raw = _preferences.read(_key);
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
      _preferences.write(_key, jsonEncode(settings.toJson()));
}
