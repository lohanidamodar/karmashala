import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;

import '../domain/settings.dart';

/// Persists [Settings] as one preference (JSON) at the server.
class SettingsRepository {
  SettingsRepository(this._preferences);

  final PreferenceStore _preferences;
  static const key = 'settings.v1';

  Settings load() => decode(raw());

  /// The stored JSON, or null when nothing was ever saved.
  String? raw() => _preferences.read(key);

  void save(Settings settings) => saveRaw(encode(settings));

  /// Writes [raw], as [encode] made it.
  void saveRaw(String raw) => _preferences.write(key, raw);

  static String encode(Settings settings) => jsonEncode(settings.toJson());

  /// [raw] as stored, or the defaults when it is absent or unreadable.
  static Settings decode(String? raw) {
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
}
