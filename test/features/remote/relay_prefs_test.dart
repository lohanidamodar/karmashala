/// The two-relay settings model: independent switches, every combination
/// legal, persisted, and seeded from the old either/or mode so an existing
/// setup wakes up on the relay it was already using.
library;

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/remote/application/relay_prefs.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/relay_mode.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('nothing stored: the legacy hosted mode means hosted on, local off', () {
    expect(
      open().read(relayPrefsProvider),
      const RelayPrefs(localEnabled: false, hostedEnabled: true),
    );
  });

  test('a legacy local-mode setup wakes up with the local relay on', () {
    final first = open();
    first
        .read(settingsControllerProvider.notifier)
        .setRemoteRelayMode(RelayMode.local);

    // A fresh container is a fresh launch reading the same database.
    expect(
      open().read(relayPrefsProvider),
      const RelayPrefs(localEnabled: true, hostedEnabled: false),
      reason: 'nobody who had local mode should find it switched off',
    );
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

  test('stored prefs beat the legacy mode — turning local off stays off', () {
    final first = open();
    first
        .read(settingsControllerProvider.notifier)
        .setRemoteRelayMode(RelayMode.local);
    first.read(relayPrefsProvider.notifier).setLocalEnabled(false);

    expect(open().read(relayPrefsProvider).localEnabled, isFalse);
  });

  test('unreadable stored prefs fall back to the legacy mode', () {
    db.writeMetadata(kRelayPrefsMetadataKey, '{not json');

    expect(RelayPrefsController.readFrom(db), isNull);
    expect(open().read(relayPrefsProvider).hostedEnabled, isTrue);
  });
}
