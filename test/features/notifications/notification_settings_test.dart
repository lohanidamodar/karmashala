import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala_notifications/persistence.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the defaults are restrained but useful', () {
    const defaults = NotificationSettings();
    expect(defaults.enabled, isTrue);
    expect(defaults.onlyWhenUnfocused, isTrue);
    expect(defaults.notifyWhenFinished, isTrue);
    expect(defaults.notifyWhenAttentionNeeded, isTrue);
  });

  test('survives a JSON round-trip', () {
    const settings = NotificationSettings(
      enabled: false,
      onlyWhenUnfocused: false,
      notifyWhenFinished: false,
      notifyWhenAttentionNeeded: false,
    );
    expect(NotificationSettings.fromJson(settings.toJson()), settings);
  });

  test('an absent or malformed field falls back to its default', () {
    expect(
      NotificationSettings.fromJson(const {}),
      const NotificationSettings(),
    );
    expect(
      NotificationSettings.fromJson(const {'enabled': 'yes please'}),
      const NotificationSettings(),
    );
  });

  test('participates in equality', () {
    expect(
      const NotificationSettings(onlyWhenUnfocused: false),
      isNot(const NotificationSettings()),
    );
  });

  group('persistence', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = AppDatabase.memory();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);
      addTearDown(db.close);
    });

    test('the controller writes every change through', () {
      container
          .read(notificationSettingsControllerProvider.notifier)
          .setOnlyWhenUnfocused(false);

      expect(
        NotificationSettingsRepository(db).load().onlyWhenUnfocused,
        isFalse,
      );
    });

    test('an empty store reads back as the defaults', () {
      expect(
        container.read(notificationSettingsControllerProvider),
        const NotificationSettings(),
      );
    });

    test('it keeps its own key, clear of the shared settings record', () {
      // Loop 42 did not edit `Settings`, so the two must round-trip
      // independently rather than clobber one another.
      container
          .read(notificationSettingsControllerProvider.notifier)
          .setEnabled(false);
      container.read(settingsControllerProvider.notifier).setKeepAwake(true);

      expect(
        container.read(notificationSettingsControllerProvider).enabled,
        isFalse,
      );
      expect(container.read(settingsControllerProvider).keepAwake, isTrue);
    });
  });
}
