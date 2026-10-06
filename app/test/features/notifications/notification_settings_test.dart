import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/data/device_notification_store.dart';
import 'package:karmashala_notifications/persistence.dart';
import 'package:karmashala_notifications/policy.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/fake_data_server.dart';

void main() {
  test('the defaults are restrained but useful', () {
    const defaults = NotificationSettings();
    expect(defaults.enabled, isTrue);
    expect(defaults.level, NotifyLevel.everything);
    expect(defaults.onlyWhenUnfocused, isTrue);
  });

  test('survives a JSON round-trip', () {
    const settings = NotificationSettings(
      level: NotifyLevel.whenNeeded,
      onlyWhenUnfocused: false,
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
    expect(
      const NotificationSettings(level: NotifyLevel.nothing),
      isNot(const NotificationSettings()),
    );
  });

  group('persistence', () {
    late FakeDataServer server;
    late ProviderContainer container;

    setUp(() async {
      server = FakeDataServer();
      container = ProviderContainer(overrides: [await server.override()]);
      addTearDown(container.dispose);
    });

    NotificationSettings stored() => NotificationSettingsRepository(
      read: server.store.read,
      write: server.store.write,
    ).load();

    test('the controller writes every change through', () async {
      container
          .read(notificationSettingsControllerProvider.notifier)
          .setOnlyWhenUnfocused(false);

      await pumpEventQueue();
      expect(stored().onlyWhenUnfocused, isFalse);
    });

    test('the level is written through too', () async {
      container
          .read(notificationSettingsControllerProvider.notifier)
          .setLevel(NotifyLevel.whenNeeded);

      await pumpEventQueue();
      expect(stored().level, NotifyLevel.whenNeeded);
    });

    test('an empty store reads back as the defaults', () {
      expect(
        container.read(notificationSettingsControllerProvider),
        const NotificationSettings(),
      );
    });

    test('a desktop record from before levels reads as one', () async {
      final older = FakeDataServer();
      older.store.write(
        'notifications.v1',
        jsonEncode({
          'enabled': true,
          'onlyWhenUnfocused': true,
          'notifyWhenFinished': false,
          'notifyWhenAttentionNeeded': true,
        }),
      );
      final reading = ProviderContainer(
        overrides: [await older.override()],
      );
      addTearDown(reading.dispose);
      expect(
        reading.read(notificationSettingsControllerProvider).level,
        NotifyLevel.whenNeeded,
      );
    });

    test('it keeps its own key, clear of the shared settings record', () {
      // Loop 42 did not edit `Settings`, so the two must round-trip
      // independently rather than clobber one another.
      container
          .read(notificationSettingsControllerProvider.notifier)
          .setLevel(NotifyLevel.nothing);
      container.read(settingsControllerProvider.notifier).setKeepAwake(true);

      expect(
        container.read(notificationSettingsControllerProvider).enabled,
        isFalse,
      );
      expect(container.read(settingsControllerProvider).keepAwake, isTrue);
    });
  });

  group('on a phone', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ks_notify_device_');
      file = File('${dir.path}${Platform.pathSeparator}notifications_device.json');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    DeviceNotificationStore store() =>
        DeviceNotificationStore(directory: () async => dir);

    test('a phone file from before levels reads as one', () async {
      file.writeAsStringSync(
        jsonEncode({
          'enabled': true,
          'notifyWhenFinished': false,
          'notifyWhenAttentionNeeded': true,
          'permissionAsked': true,
        }),
      );
      expect((await store().loadSettings()).level, NotifyLevel.whenNeeded);
    });

    test('the master switch off reads as Nothing', () async {
      file.writeAsStringSync(jsonEncode({'enabled': false}));
      expect((await store().loadSettings()).level, NotifyLevel.nothing);
    });

    test('a saved level comes back, and the permission flag stays', () async {
      file.writeAsStringSync(jsonEncode({'permissionAsked': true}));
      final first = store();
      await first.saveSettings(
        const NotificationSettings(level: NotifyLevel.whenNeeded),
      );
      final again = store();
      expect((await again.loadSettings()).level, NotifyLevel.whenNeeded);
      expect(await again.permissionAsked(), isTrue);
      // What a phone from before levels reads: finished off, needs-you on.
      final kept = jsonDecode(file.readAsStringSync()) as Map;
      expect(kept['notifyWhenFinished'], isFalse);
      expect(kept['notifyWhenAttentionNeeded'], isTrue);
    });
  });
}
