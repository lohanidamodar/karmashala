/// The two-relay settings model: the embedded local relay and the hosted one
/// are independent switches — both on, either, or none (Loop 80, direct owner
/// ask: "one device via local and another via remote").
///
/// Owned by the remote feature and persisted in `app_metadata` rather than in
/// `Settings`: the settings feature is another loop's territory, and these two
/// booleans configure nothing but the remote host. The legacy either/or
/// `Settings.remoteRelayMode` seeds the first read, so an existing local-mode
/// setup wakes up with the local relay on and the hosted one off.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/relay_mode.dart';

/// Where the prefs live in the `app_metadata` key/value table.
const String kRelayPrefsMetadataKey = 'remote.relay_prefs.v1';

/// Which relays remote access serves through. Any combination is legal;
/// with both off the host still answers direct LAN links, but offers no
/// relay for phones elsewhere and no endpoint for new pairings.
class RelayPrefs {
  const RelayPrefs({required this.localEnabled, required this.hostedEnabled});

  /// The embedded relay this computer runs itself (`ws://<lan-ip>:<port>`).
  final bool localEnabled;

  /// A relay on the internet: the PopupBits default or a self-hosted URL.
  final bool hostedEnabled;

  bool get anyEnabled => localEnabled || hostedEnabled;

  RelayPrefs copyWith({bool? localEnabled, bool? hostedEnabled}) => RelayPrefs(
    localEnabled: localEnabled ?? this.localEnabled,
    hostedEnabled: hostedEnabled ?? this.hostedEnabled,
  );

  Map<String, Object?> toJson() => {
    'local': localEnabled,
    'hosted': hostedEnabled,
  };

  @override
  bool operator ==(Object other) =>
      other is RelayPrefs &&
      other.localEnabled == localEnabled &&
      other.hostedEnabled == hostedEnabled;

  @override
  int get hashCode => Object.hash(localEnabled, hostedEnabled);

  @override
  String toString() =>
      'RelayPrefs(local: $localEnabled, hosted: $hostedEnabled)';
}

class RelayPrefsController extends Notifier<RelayPrefs> {
  @override
  RelayPrefs build() {
    final stored = readFrom(ref.watch(databaseProvider));
    if (stored != null) return stored;
    // First run after the upgrade: the old either/or mode says which single
    // relay this setup was using, and that one stays on.
    final legacy = ref.read(settingsControllerProvider).remoteRelayMode;
    return legacy == RelayMode.local
        ? const RelayPrefs(localEnabled: true, hostedEnabled: false)
        : const RelayPrefs(localEnabled: false, hostedEnabled: true);
  }

  /// The persisted prefs, or null when nothing has been written yet (the
  /// legacy mode then decides). Static so a test can read what a fresh launch
  /// would load, the way `SettingsRepository(db).load()` is used.
  static RelayPrefs? readFrom(AppDatabase db) {
    final raw = db.readMetadata(kRelayPrefsMetadataKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return RelayPrefs(
          localEnabled: decoded['local'] == true,
          hostedEnabled: decoded['hosted'] == true,
        );
      }
    } on FormatException {
      // Unreadable — treated as never written.
    }
    return null;
  }

  void setLocalEnabled(bool value) =>
      _save(state.copyWith(localEnabled: value));

  void setHostedEnabled(bool value) =>
      _save(state.copyWith(hostedEnabled: value));

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
