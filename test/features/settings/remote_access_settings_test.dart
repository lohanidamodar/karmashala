import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/settings/application/settings_controller.dart';
import 'package:chitragupta/src/features/settings/data/settings_repository.dart';
import 'package:chitragupta/src/features/settings/domain/settings.dart';
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
