/// The controller runs no companion server of its own: phones are the
/// server's, pairing needs the link to it, and a person's rename, grant and
/// revoke go through the server's data API.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/remote_providers.dart';
import 'package:karmashala_remote/remote.dart';

import '../../support/fake_data_server.dart';
import '../../support/memory_server_config.dart';

void main() {
  group('resolveRelayUri', () {
    test('null, empty and junk fall back to the PopupBits default', () {
      expect(resolveRelayUri(null), Uri.parse(kDefaultRelayUrl));
      expect(resolveRelayUri('   '), Uri.parse(kDefaultRelayUrl));
      expect(resolveRelayUri('not a url'), Uri.parse(kDefaultRelayUrl));
    });

    test('a configured relay wins', () {
      expect(
        resolveRelayUri('wss://relay.example.com:8443/base'),
        Uri.parse('wss://relay.example.com:8443/base'),
      );
    });
  });

  group('the controller', () {
    late FakeDataServer server;
    late ProviderContainer container;
    late RemoteAccessController controller;
    final id = 'c' * 32;

    setUp(() async {
      server = FakeDataServer();
      server.deviceRows.insert(
        PairedDevice(
          id: id,
          name: 'OPPO',
          deviceKey: Uint8List.fromList(List.filled(32, 7)),
          capabilities: CapabilitySet.all,
          generation: 3,
          createdAt: DateTime.utc(2026, 8, 31),
          pushToken: 'token',
        ),
      );
      container = ProviderContainer(
        overrides: [
          await server.override(),
          serverConfigIn(MemoryServerConfigSource()),
          remoteAccessControllerProvider.overrideWith(
            RemoteAccessController.new,
          ),
        ],
      );
      addTearDown(container.dispose);
      controller = container.read(remoteAccessControllerProvider);
    });

    test('pairing with no link to the server is a StateError', () async {
      setRemoteAccessNow(container, enabled: true);
      await controller.sync();

      expect(
        () => controller.beginPairing(capabilities: CapabilitySet.all),
        throwsStateError,
      );
    });

    test('the list is the server\'s, with no key or push token', () {
      final listed = container.read(pairedDevicesProvider).single;
      expect(listed.name, 'OPPO');
      expect(listed.deviceKey, isEmpty);
      expect(listed.pushToken, isNull);
    });

    test('rename, grant and revoke go through the server', () async {
      final device = container.read(pairedDevicesProvider).single;
      await controller.rename(device, '  Work phone ');
      await controller.updateCapabilities(device, CapabilitySet.none);
      await controller.revoke(device);

      expect(server.deviceRows.applied, [
        'devices.rename',
        'devices.grant',
        'devices.revoke',
      ]);
      final stored = server.deviceRows.getById(id)!;
      expect(stored.name, 'Work phone');
      expect(stored.revoked, isTrue);
      expect(stored.deviceKey, isEmpty);
      expect(container.read(pairedDevicesProvider).single.revoked, isTrue);
    });

    test('a refused write changes nothing and does not throw', () async {
      final device = container.read(pairedDevicesProvider).single;
      await controller.rename(device, '   ');
      expect(server.deviceRows.getById(id)!.name, 'OPPO');
    });

    test('a device the server records itself reaches the list', () async {
      final sub = container.listen(pairedDevicesProvider, (_, _) {});
      addTearDown(sub.close);
      server.deviceRows.insert(
        PairedDevice(
          id: 'd' * 32,
          name: 'Tablet',
          deviceKey: Uint8List(32),
          capabilities: CapabilitySet.all,
          generation: 1,
          createdAt: DateTime.utc(2026, 9, 1),
        ),
      );
      await pumpEventQueue();
      expect(sub.read().map((d) => d.name), ['Tablet', 'OPPO']);
    });
  });
}
