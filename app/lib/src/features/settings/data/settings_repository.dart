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

  void save(Settings settings) => saveRaw(encode(settings, over: raw()));

  /// Writes [raw], as [encode] made it.
  void saveRaw(String raw) => _preferences.write(key, raw);

  /// [settings] laid over [over] (what is stored): keys this build does not
  /// know are kept, so an older client's save cannot drop a newer one's.
  static String encode(Settings settings, {String? over}) {
    final kept = <String, dynamic>{};
    if (over != null) {
      try {
        final stored = jsonDecode(over);
        if (stored is Map<String, dynamic>) {
          for (final entry in stored.entries) {
            if (!Settings.jsonKeys.contains(entry.key)) {
              kept[entry.key] = entry.value;
            }
          }
        }
      } on FormatException {
        // Unreadable: nothing to keep.
      }
    }
    return jsonEncode({...kept, ...settings.toJson()});
  }

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
