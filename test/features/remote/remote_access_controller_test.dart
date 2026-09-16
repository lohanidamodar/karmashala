/// The on/off contract: nothing runs until settings say so, the relay change
/// restarts, revocation works while off, and shutdown is clean.
library;

import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

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
    late AppDatabase db;
    late ProviderContainer container;
    late RelayServer relay;
    late RemoteAccessController controller;

    setUp(() async {
      db = AppDatabase.memory();
      relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
      final fake = FakeRemoteBindings()..addSession('s1');
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          remoteAccessControllerProvider.overrideWith(
            (ref) => RemoteAccessController(
              ref,
              serviceFactory: (relayUri) => RemoteHostService(
                devices: PairedDeviceDao(db),
                hostId: DeviceId.parse('11111111222222223333333344444444'),
                bindings: fake.bindings,
                relay: relayUri,
                lanPort: 0,
                advertise: false,
                transcriptPollInterval: Duration.zero,
                relayFactory: (relay, rendezvous) => RelayTransport(
                  endpoint: RelayTransport.endpointFor(relay, rendezvous),
                  backoff: fastBackoff(),
                  heartbeat: const Duration(milliseconds: 500),
                )..start(),
              ),
            ),
          ),
        ],
      );
      controller = container.read(remoteAccessControllerProvider);
    });

    tearDown(() async {
      await controller.shutdown();
      container.dispose();
      await relay.close();
      db.close();
    });

    test('OFF by default: mounting the controller starts nothing', () async {
      await controller.sync();

      expect(controller.service, isNull);
      expect(controller.isRunning, isFalse);
    });

    test('enabling starts the service; disabling stops it', () async {
      final settings = container.read(settingsControllerProvider.notifier);

      settings.setRemoteAccessEnabled(true);
      settings.setRemoteRelayUrl('http://127.0.0.1:${relay.port}');
      await controller.sync();
      expect(controller.isRunning, isTrue);
      expect(controller.service!.lanPortBound, isNotNull);

      settings.setRemoteAccessEnabled(false);
      await controller.sync();
      expect(controller.service, isNull);
    });

    test('a moved relay URL restarts onto the new relay', () async {
      final settings = container.read(settingsControllerProvider.notifier);
      settings.setRemoteAccessEnabled(true);
      settings.setRemoteRelayUrl('http://127.0.0.1:${relay.port}');
      await controller.sync();
      final first = controller.service!;

      final second = await RelayServer.bind(address: '127.0.0.1', port: 0);
      addTearDown(second.close);
      settings.setRemoteRelayUrl('http://127.0.0.1:${second.port}');
      await controller.sync();

      expect(controller.service, isNot(same(first)));
      expect(controller.service!.relay.port, second.port);
      expect(first.isRunning, isFalse, reason: 'the old service was stopped');
    });

    test('an unchanged relay does not restart the service', () async {
      final settings = container.read(settingsControllerProvider.notifier);
      settings.setRemoteAccessEnabled(true);
      settings.setRemoteRelayUrl('http://127.0.0.1:${relay.port}');
      await controller.sync();
      final first = controller.service!;

      await controller.sync();

      expect(controller.service, same(first));
    });

    test('pairing while off is a StateError the dialog can show', () async {
      await controller.sync();

      expect(
        () => controller.beginPairing(capabilities: CapabilitySet.all),
        throwsStateError,
      );
    });

    test('revocation never waits for a listener', () async {
      final dao = PairedDeviceDao(db);
      dao.insert(
        PairedDevice(
          id: 'c' * 32,
          name: 'OPPO',
          deviceKey: Uint8List(32),
          capabilities: CapabilitySet.all,
          generation: 1,
          createdAt: DateTime.utc(2026, 8, 31),
        ),
      );

      await controller.revoke(dao.getById('c' * 32)!);

      expect(dao.getById('c' * 32)!.revoked, isTrue);
      expect(dao.getById('c' * 32)!.deviceKey, isEmpty);
    });
  });
}
