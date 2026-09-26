/// The embedded relay's switch: this app's own listener, so its preference is
/// the app's — kept at the server. The internet relay is the server's config,
/// never kept here. The v50 upgrade that seeds it from the retired either/or
/// mode is tested in `packages/karmashala_store/test/relay_prefs_migration_test`.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/relay_prefs.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/data/settings_repository.dart';

import '../../support/fake_data_server.dart';

void main() {
  late FakeDataServer server;

  setUp(() => server = FakeDataServer());

  /// A launch: a fresh client of the same server.
  Future<ProviderContainer> open() async {
    final container = ProviderContainer(overrides: [await server.override()]);
    addTearDown(container.dispose);
    return container;
  }

  test('nothing stored: the embedded relay is off', () async {
    expect(
      (await open()).read(relayPrefsProvider),
      const RelayPrefs(localEnabled: false),
    );
  });

  test('settings that still carry old keys load and save, and the retired '
      'remote-access keys are neither read nor written', () async {
    server.store.write(
      'settings.v1',
      jsonEncode({
        'remoteRelayMode': 'local',
        'remoteAccessEnabled': true,
        'remoteRelayUrl': 'wss://relay.example.com',
        'localRelayPort': 9001,
      }),
    );
    final container = await open();
    expect(container.read(settingsControllerProvider).localRelayPort, 9001);

    container.read(settingsControllerProvider.notifier).setLocalRelayPort(9002);
    await pumpEventQueue();
    final saved = SettingsRepository(server.store).load();
    expect(saved.localRelayPort, 9002);
    expect(saved.toJson(), isNot(contains('remoteAccessEnabled')));
    expect(saved.toJson(), isNot(contains('remoteRelayUrl')));
  });

  test('both values survive a relaunch', () async {
    for (final wanted in const [
      RelayPrefs(localEnabled: true),
      RelayPrefs(localEnabled: false),
    ]) {
      final container = await open();
      container
          .read(relayPrefsProvider.notifier)
          .setLocalEnabled(wanted.localEnabled);

      expect(container.read(relayPrefsProvider), wanted);
      await pumpEventQueue();
      expect(RelayPrefsController.readFrom(server.store), wanted);
      expect(
        (await open()).read(relayPrefsProvider),
        wanted,
        reason: 'relaunch',
      );
    }
  });

  test(
    'a stored "hosted" from before is ignored: that is the server\'s',
    () async {
      server.store.write(
        kRelayPrefsMetadataKey,
        jsonEncode({'local': true, 'hosted': false}),
      );
      expect(
        (await open()).read(relayPrefsProvider),
        const RelayPrefs(localEnabled: true),
      );
    },
  );

  test('unreadable stored prefs fall back to off', () async {
    server.store.write(kRelayPrefsMetadataKey, '{not json');

    expect(RelayPrefsController.readFrom(server.store), isNull);
    expect((await open()).read(relayPrefsProvider).localEnabled, isFalse);
  });
}
