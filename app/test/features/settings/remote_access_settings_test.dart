import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('remote access settings', () {
    test('remote access is off by default, with no relay override', () {
      // A listener nobody asked for is the one default this feature must
      // never ship with.
      expect(const Settings().remoteAccessEnabled, isFalse);
      expect(const Settings().remoteRelayUrl, isNull);
    });

    test('both fields survive a JSON round-trip', () {
      const s = Settings(
        remoteAccessEnabled: true,
        remoteRelayUrl: 'wss://relay.example.com',
      );
      final restored = Settings.fromJson(s.toJson());
      expect(restored.remoteAccessEnabled, isTrue);
      expect(restored.remoteRelayUrl, 'wss://relay.example.com');
      expect(restored, s);
    });

    test('absent keys read back as the defaults', () {
      final restored = Settings.fromJson(const {});
      expect(restored.remoteAccessEnabled, isFalse);
      expect(restored.remoteRelayUrl, isNull);
    });

    test('both fields participate in equality', () {
      expect(
        const Settings(remoteAccessEnabled: true),
        isNot(const Settings()),
      );
      expect(
        const Settings(remoteRelayUrl: 'wss://a'),
        isNot(const Settings(remoteRelayUrl: 'wss://b')),
      );
    });

    test('the local relay defaults to the standard port', () {
      expect(const Settings().localRelayPort, 8787);
    });

    test('the port survives a JSON round-trip', () {
      const s = Settings(localRelayPort: 9001);
      final restored = Settings.fromJson(s.toJson());
      expect(restored.localRelayPort, 9001);
      expect(restored, s);
    });

    test('a junk port reads back as the default', () {
      final restored = Settings.fromJson(const {
        'localRelayPort': 'yes please',
      });
      expect(restored.localRelayPort, 8787);
    });

    test('the retired relay mode is neither read nor written', () {
      // Carried into remote.relay_prefs.v1 by the store's v50 upgrade.
      final restored = Settings.fromJson(const {'remoteRelayMode': 'local'});
      expect(restored, const Settings());
      expect(const Settings().toJson(), isNot(contains('remoteRelayMode')));
    });

    test('the port participates in equality', () {
      expect(const Settings(localRelayPort: 9001), isNot(const Settings()));
    });

    test('the controller persists the port', () {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      final controller = container.read(settingsControllerProvider.notifier);

      controller.setLocalRelayPort(9001);

      final stored = SettingsRepository(db).load();
      expect(stored.localRelayPort, 9001);
    });

    test(
      'the controller persists the toggle and the relay, and can clear it',
      () {
        final db = AppDatabase.memory();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );
        addTearDown(container.dispose);
        final controller = container.read(settingsControllerProvider.notifier);

        controller.setRemoteAccessEnabled(true);
        controller.setRemoteRelayUrl('wss://relay.example.com');

        var stored = SettingsRepository(db).load();
        expect(stored.remoteAccessEnabled, isTrue);
        expect(stored.remoteRelayUrl, 'wss://relay.example.com');

        // Clearing must actually clear — `?? this.x` cannot say "back to null".
        controller.setRemoteRelayUrl(null);
        stored = SettingsRepository(db).load();
        expect(stored.remoteRelayUrl, isNull);
      },
    );
  });
}
