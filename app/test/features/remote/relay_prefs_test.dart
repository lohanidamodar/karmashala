/// The embedded relay's switch: this app's own listener, so its preference is
/// the app's — persisted, and seeded by the v50 upgrade from the retired
/// either/or mode so an existing setup wakes up on the relay it was using.
/// The internet relay is the server's config, never kept here.
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
import '../../support/stored_preferences.dart';

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

  test('nothing stored: the embedded relay is off', () {
    expect(
      open().read(relayPrefsProvider),
      const RelayPrefs(localEnabled: false),
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

    test('a local-mode setup wakes up with the local relay on', () {
      final container = upgrade(
        _before50(settings: {'remoteRelayMode': 'local'}),
      );

      const local = RelayPrefs(localEnabled: true);
      expect(
        container.read(relayPrefsProvider),
        local,
        reason: 'nobody who had local mode should find it switched off',
      );
      // Written by the upgrade, so the next settings save — which no longer
      // carries the old key — cannot take it away.
      expect(
        RelayPrefsController.readFrom(
          StoredPreferences(container.read(databaseProvider)),
        ),
        local,
      );
    });

    test('a hosted-mode, junk or mode-less setup has it off', () {
      for (final settings in <Map<String, Object?>?>[
        {'remoteRelayMode': 'hosted'},
        {'remoteRelayMode': 'teleport'},
        {'remoteAccessEnabled': true},
        null,
      ]) {
        final container = upgrade(_before50(settings: settings));
        expect(
          container.read(relayPrefsProvider),
          const RelayPrefs(localEnabled: false),
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
        const RelayPrefs(localEnabled: false),
      );
    });

    test('settings that still carry old keys load and save, and the '
        'retired remote-access keys are neither read nor written', () {
      final container = upgrade(
        _before50(
          settings: {
            'remoteRelayMode': 'local',
            'remoteAccessEnabled': true,
            'remoteRelayUrl': 'wss://relay.example.com',
            'localRelayPort': 9001,
          },
        ),
      );
      final db = container.read(databaseProvider);

      final loaded = container.read(settingsControllerProvider);
      expect(loaded.localRelayPort, 9001);

      container
          .read(settingsControllerProvider.notifier)
          .setLocalRelayPort(9002);
      final saved = SettingsRepository(StoredPreferences(db)).load();
      expect(saved.localRelayPort, 9002);
      expect(saved.toJson(), isNot(contains('remoteAccessEnabled')));
      expect(saved.toJson(), isNot(contains('remoteRelayUrl')));
      expect(
        RelayPrefsController.readFrom(StoredPreferences(db))?.localEnabled,
        isTrue,
      );
    });
  });

  test('both values survive a relaunch', () {
    for (final wanted in const [
      RelayPrefs(localEnabled: true),
      RelayPrefs(localEnabled: false),
    ]) {
      final container = open();
      container
          .read(relayPrefsProvider.notifier)
          .setLocalEnabled(wanted.localEnabled);

      expect(container.read(relayPrefsProvider), wanted);
      expect(RelayPrefsController.readFrom(StoredPreferences(db)), wanted);
      expect(open().read(relayPrefsProvider), wanted, reason: 'relaunch');
    }
  });

  test('a stored "hosted" from before is ignored: that is the server\'s', () {
    db.writeMetadata(
      kRelayPrefsMetadataKey,
      jsonEncode({'local': true, 'hosted': false}),
    );
    expect(
      open().read(relayPrefsProvider),
      const RelayPrefs(localEnabled: true),
    );
  });

  test('unreadable stored prefs fall back to off', () {
    db.writeMetadata(kRelayPrefsMetadataKey, '{not json');

    expect(RelayPrefsController.readFrom(StoredPreferences(db)), isNull);
    expect(open().read(relayPrefsProvider).localEnabled, isFalse);
  });
}
