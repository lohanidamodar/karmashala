import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Schema v50: the retired either/or `remoteRelayMode` in `settings.v1`
/// seeds the app's relay preference (`remote.relay_prefs.v1`), so a setup
/// that used the local relay wakes up with it on. Moved here from the app,
/// which reads preferences only through the server.
const _prefsKey = 'remote.relay_prefs.v1';

/// A database as the release before v50 left it.
AppDatabase _upgradedFrom49({Map<String, Object?>? settings, String? prefs}) {
  final raw = sqlite3.openInMemory();
  final versions = schemaMigrations.keys.where((v) => v < 50).toList()..sort();
  for (final version in versions) {
    schemaMigrations[version]!(raw);
    raw.execute('PRAGMA user_version = $version;');
  }
  void put(String key, String value) => raw.execute(
    'INSERT INTO app_metadata (key, value, updated_at) VALUES (?, ?, ?);',
    [key, value, '2026-09-01T00:00:00.000Z'],
  );
  if (settings != null) put('settings.v1', jsonEncode(settings));
  if (prefs != null) put(_prefsKey, prefs);
  return AppDatabase(raw);
}

bool? _local(AppDatabase db) {
  final raw = db.readMetadata(_prefsKey);
  return raw == null ? null : (jsonDecode(raw) as Map)['local'] as bool?;
}

void main() {
  test('a local-mode setup gets the local relay switched on', () {
    final db = _upgradedFrom49(settings: {'remoteRelayMode': 'local'});
    addTearDown(db.close);
    expect(_local(db), isTrue);
  });

  test('a hosted-mode, junk or mode-less setup gets nothing written', () {
    for (final settings in <Map<String, Object?>?>[
      {'remoteRelayMode': 'hosted'},
      {'remoteRelayMode': 'teleport'},
      {'remoteAccessEnabled': true},
      null,
    ]) {
      final db = _upgradedFrom49(settings: settings);
      addTearDown(db.close);
      expect(_local(db), isNull, reason: '$settings');
    }
  });

  test('prefs already written win over the old mode', () {
    final db = _upgradedFrom49(
      settings: {'remoteRelayMode': 'local'},
      prefs: jsonEncode({'local': false, 'hosted': false}),
    );
    addTearDown(db.close);
    expect(_local(db), isFalse);
  });

  test('the old settings keys are left for the app to ignore', () {
    final db = _upgradedFrom49(
      settings: {
        'remoteRelayMode': 'local',
        'remoteAccessEnabled': true,
        'localRelayPort': 9001,
      },
    );
    addTearDown(db.close);
    final settings =
        jsonDecode(db.readMetadata('settings.v1')!) as Map<String, Object?>;
    expect(settings['localRelayPort'], 9001);
    expect(_local(db), isTrue);
  });
}
