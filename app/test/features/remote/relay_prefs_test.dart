/// The two-relay settings model: independent switches, every combination
/// legal, persisted, and seeded by the v50 upgrade from the retired either/or
/// mode so an existing setup wakes up on the relay it was already using.
library;

import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/migrations.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/remote/application/relay_prefs.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// A database as the release before v50 left it, with [settings] as its
/// stored `settings.v1` and, optionally, relay prefs already written.
Database _before50({Map<String, Object?>? settings, String? prefs}) {
  final db = sqlite3.openInMemory();
  final versions = schemaMigrations.keys.where((v) => v < 50).toList()..sort();
  for (final version in versions) {
    schemaMigrations[version]!(db);
    db.execute('PRAGMA user_version = $version;');
  }
  void put(String key, String value) => db.execute(
    'INSERT INTO app_metadata (key, value, updated_at) VALUES (?, ?, ?);',
    [key, value, '2026-09-01T00:00:00.000Z'],
  );
  if (settings != null) put('settings.v1', jsonEncode(settings));
  if (prefs != null) put(kRelayPrefsMetadataKey, prefs);
  return db;
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  ProviderContainer open() {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('nothing stored: hosted on, local off', () {
    expect(
      open().read(relayPrefsProvider),
      const RelayPrefs(localEnabled: false, hostedEnabled: true),
    );
  });

  group('upgrading from the either/or relay mode', () {
    ProviderContainer upgrade(Database raw) {
      final upgraded = AppDatabase(raw);
      addTearDown(upgraded.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(upgraded)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a local-mode setup wakes up with only the local relay on', () {
      final container = upgrade(
        _before50(settings: {'remoteRelayMode': 'local'}),
      );

      const local = RelayPrefs(localEnabled: true, hostedEnabled: false);
      expect(
        container.read(relayPrefsProvider),
        local,
        reason: 'nobody who had local mode should find it switched off',
      );
      // Written by the upgrade, so the next settings save — which no longer
      // carries the old key — cannot take it away.
      expect(
        RelayPrefsController.readFrom(container.read(databaseProvider)),
        local,
      );
    });

    test('a hosted-mode, junk or mode-less setup stays on hosted', () {
      for (final settings in <Map<String, Object?>?>[
        {'remoteRelayMode': 'hosted'},
        {'remoteRelayMode': 'teleport'},
        {'remoteAccessEnabled': true},
        null,
      ]) {
        final container = upgrade(_before50(settings: settings));
        expect(
          container.read(relayPrefsProvider),
          const RelayPrefs(localEnabled: false, hostedEnabled: true),
          reason: '$settings',
        );
      }
    });

    test('prefs already written win over the old mode', () {
      final container = upgrade(
        _before50(
          settings: {'remoteRelayMode': 'local'},
          prefs: jsonEncode({'local': false, 'hosted': false}),
        ),
      );

      expect(
        container.read(relayPrefsProvider),
        const RelayPrefs(localEnabled: false, hostedEnabled: false),
      );
    });

    test('settings that still carry the old key load and save', () {
      final container = upgrade(
        _before50(
          settings: {
            'remoteRelayMode': 'local',
            'remoteAccessEnabled': true,
            'localRelayPort': 9001,
          },
        ),
      );
      final db = container.read(databaseProvider);

      final loaded = container.read(settingsControllerProvider);
      expect(loaded.remoteAccessEnabled, isTrue);
      expect(loaded.localRelayPort, 9001);

      container
          .read(settingsControllerProvider.notifier)
          .setLocalRelayPort(9002);
      expect(SettingsRepository(db).load().localRelayPort, 9002);
      expect(RelayPrefsController.readFrom(db)?.localEnabled, isTrue);
    });
  });

  test('every combination is legal and survives a relaunch', () {
    for (final wanted in const [
      RelayPrefs(localEnabled: true, hostedEnabled: true),
      RelayPrefs(localEnabled: true, hostedEnabled: false),
      RelayPrefs(localEnabled: false, hostedEnabled: true),
      RelayPrefs(localEnabled: false, hostedEnabled: false),
    ]) {
      final container = open();
      container.read(relayPrefsProvider.notifier)
        ..setLocalEnabled(wanted.localEnabled)
        ..setHostedEnabled(wanted.hostedEnabled);

      expect(container.read(relayPrefsProvider), wanted);
      expect(RelayPrefsController.readFrom(db), wanted);
      expect(open().read(relayPrefsProvider), wanted, reason: 'relaunch');
    }
  });

  test('the switches are independent — one never moves the other', () {
    final container = open();
    final prefs = container.read(relayPrefsProvider.notifier);

    prefs.setLocalEnabled(true);
    expect(container.read(relayPrefsProvider).hostedEnabled, isTrue);
    prefs.setHostedEnabled(false);
    expect(container.read(relayPrefsProvider).localEnabled, isTrue);
    prefs.setLocalEnabled(false);
    expect(container.read(relayPrefsProvider).hostedEnabled, isFalse);
  });

  test('anyEnabled is the "remote access is idle" question', () {
    expect(
      const RelayPrefs(localEnabled: false, hostedEnabled: false).anyEnabled,
      isFalse,
    );
    expect(
      const RelayPrefs(localEnabled: true, hostedEnabled: false).anyEnabled,
      isTrue,
    );
    expect(
      const RelayPrefs(localEnabled: false, hostedEnabled: true).anyEnabled,
      isTrue,
    );
  });

  test('unreadable stored prefs fall back to hosted', () {
    db.writeMetadata(kRelayPrefsMetadataKey, '{not json');

    expect(RelayPrefsController.readFrom(db), isNull);
    expect(open().read(relayPrefsProvider).hostedEnabled, isTrue);
  });
}
