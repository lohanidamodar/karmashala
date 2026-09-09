/// v19's backfill: every device paired before the column existed went through
/// whatever single relay the app was configured for, because serving two at
/// once is exactly what this migration enables. The backfill is therefore a
/// *fact* about those rows, not a default — the same reasoning as v16's.
library;

import 'dart:convert';

import 'package:karmashala/src/core/database/migrations.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Applies every migration up to and including [upTo], the way `AppDatabase`
/// does, so a pre-v19 database can be populated and then migrated.
Database _migratedTo(int upTo) {
  final db = sqlite3.openInMemory();
  db.execute('PRAGMA foreign_keys = ON;');
  final versions = schemaMigrations.keys.where((v) => v <= upTo).toList()
    ..sort();
  for (final version in versions) {
    schemaMigrations[version]!(db);
    db.execute('PRAGMA user_version = $version;');
  }
  return db;
}

void _seedDevice(Database db, String id) {
  db.execute(
    'INSERT INTO paired_devices '
    '(id, name, device_key, capabilities, generation, created_at) '
    'VALUES (?, ?, ?, ?, ?, ?);',
    [id, 'OPPO', 'ab' * 32, 31, 1, '2026-08-31T00:00:00.000Z'],
  );
}

void _seedSettings(Database db, Map<String, Object?> settings) {
  db.execute(
    'INSERT INTO app_metadata (key, value, updated_at) VALUES (?, ?, ?);',
    ['settings.v1', jsonEncode(settings), '2026-08-31T00:00:00.000Z'],
  );
}

String? _relayOf(Database db, String id) =>
    db.select('SELECT relay_url FROM paired_devices WHERE id = ?;', [
          id,
        ]).first['relay_url']
        as String?;

void main() {
  test('a hosted-mode setup backfills the configured relay URL', () {
    final db = _migratedTo(18);
    addTearDown(db.close);
    _seedSettings(db, {
      'remoteAccessEnabled': true,
      'remoteRelayMode': 'hosted',
      'remoteRelayUrl': 'wss://relay.example.com:8443/base',
    });
    _seedDevice(db, 'a' * 32);

    schemaMigrations[19]!(db);

    expect(_relayOf(db, 'a' * 32), 'wss://relay.example.com:8443/base');
  });

  test('a local-mode setup backfills the local marker, not an IP', () {
    final db = _migratedTo(18);
    addTearDown(db.close);
    // The LAN address of the moment is exactly what must NOT be stored: the
    // machine's IP and the relay's port both move, "my own relay" does not.
    _seedSettings(db, {
      'remoteRelayMode': 'local',
      'remoteRelayUrl': 'wss://relay.example.com',
      'localRelayPort': 8787,
    });
    _seedDevice(db, 'b' * 32);

    schemaMigrations[19]!(db);

    expect(_relayOf(db, 'b' * 32), kLocalRelayMarker);
  });

  test('no settings, junk settings and an unusable URL all fall back to the '
      'PopupBits relay', () {
    for (final settings in <Map<String, Object?>?>[
      null,
      {'remoteRelayMode': 'hosted'},
      {'remoteRelayMode': 'hosted', 'remoteRelayUrl': '   '},
      {'remoteRelayMode': 'hosted', 'remoteRelayUrl': 'not a url'},
    ]) {
      final db = _migratedTo(18);
      addTearDown(db.close);
      if (settings != null) _seedSettings(db, settings);
      _seedDevice(db, 'c' * 32);

      schemaMigrations[19]!(db);

      expect(
        _relayOf(db, 'c' * 32),
        'wss://relay.popupbits.com',
        reason: 'the default relay is what those pairings actually used',
      );
    }
  });

  test('unreadable settings JSON does not sink the migration', () {
    final db = _migratedTo(18);
    addTearDown(db.close);
    db.execute(
      'INSERT INTO app_metadata (key, value, updated_at) VALUES (?, ?, ?);',
      ['settings.v1', '{not json', '2026-08-31T00:00:00.000Z'],
    );
    _seedDevice(db, 'd' * 32);

    schemaMigrations[19]!(db);

    expect(_relayOf(db, 'd' * 32), 'wss://relay.popupbits.com');
  });

  test('a fresh database has the column and no rows to backfill', () {
    final db = _migratedTo(19);
    addTearDown(db.close);

    final columns = db
        .select('PRAGMA table_info(paired_devices);')
        .map((r) => r['name'])
        .toList();
    expect(columns.where((c) => c == 'relay_url'), hasLength(1));
    expect(db.select('SELECT * FROM paired_devices;'), isEmpty);
  });
}
