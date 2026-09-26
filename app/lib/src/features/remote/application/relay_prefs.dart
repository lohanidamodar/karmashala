/// The embedded relay's switch: this computer's own relay is this app's
/// listener, so whether it runs is this app's preference, persisted in
/// `app_metadata`. The internet relay is the server's config
/// (`remote_access_settings.dart`), never kept here.
library;

import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_store/database.dart';
import '../../../core/database/database_providers.dart';

/// Where the prefs live in the `app_metadata` key/value table.
const String kRelayPrefsMetadataKey = 'remote.relay_prefs.v1';

/// Whether this app runs its embedded relay while remote access is on.
class RelayPrefs {
  const RelayPrefs({required this.localEnabled});

  /// The embedded relay this computer runs itself (`ws://<lan-ip>:<port>`).
  final bool localEnabled;

  RelayPrefs copyWith({bool? localEnabled}) =>
      RelayPrefs(localEnabled: localEnabled ?? this.localEnabled);

  Map<String, Object?> toJson() => {'local': localEnabled};

  @override
  bool operator ==(Object other) =>
      other is RelayPrefs && other.localEnabled == localEnabled;

  @override
  int get hashCode => localEnabled.hashCode;

  @override
  String toString() => 'RelayPrefs(local: $localEnabled)';
}

class RelayPrefsController extends Notifier<RelayPrefs> {
  @override
  RelayPrefs build() {
    final stored = readFrom(ref.watch(databaseProvider));
    return stored ?? const RelayPrefs(localEnabled: false);
  }

  /// The persisted prefs, or null when nothing was written yet, which means
  /// no embedded relay. Static, so a test can read what a fresh launch loads.
  static RelayPrefs? readFrom(AppDatabase db) {
    final raw = db.readMetadata(kRelayPrefsMetadataKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return RelayPrefs(localEnabled: decoded['local'] == true);
      }
    } on FormatException {
      // Unreadable — treated as never written.
    }
    return null;
  }

  void setLocalEnabled(bool value) =>
      _save(state.copyWith(localEnabled: value));

  void _save(RelayPrefs prefs) {
    state = prefs;
    ref
        .read(databaseProvider)
        .writeMetadata(kRelayPrefsMetadataKey, jsonEncode(prefs.toJson()));
  }
}

final relayPrefsProvider = NotifierProvider<RelayPrefsController, RelayPrefs>(
  RelayPrefsController.new,
);
