/// Where this machine has a session host, the host serves the phones: this app
/// runs no companion server, writes its Remote access settings into the
/// server's config through the host, and tells it where the app's embedded
/// relay is. Every phone call is the server's own (slice 5c): nothing is
/// forwarded here.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/host_companion_link.dart';
import 'package:karmashala/src/features/remote/application/host_companion_providers.dart';
import 'package:karmashala/src/features/remote/application/remote_access_controller.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_source.dart';
import 'package:karmashala/src/features/remote/application/remote_access_settings.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_host/server_config.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';

import '../../support/fake_data_server.dart';
import '../../support/fake_host_lifecycle.dart';
import '../../support/memory_server_config.dart';

void main() {
  late FakeHostLifecycle host;
  late HostCompanionLink link;
  late Map<String, PairedDevice> recorded;

  PairedDevice device(String id) => PairedDevice(
    id: id,
    name: 'Pixel',
    deviceKey: Uint8List.fromList(List.filled(32, 3)),
    capabilities: CapabilitySet.all,
    generation: 0,
    createdAt: DateTime.utc(2026, 9, 25),
  );

  setUp(() {
    host = FakeHostLifecycle();
    recorded = {};
    link = HostCompanionLink(deviceById: (id) async => recorded[id]);
  });

  Future<HostLifecycleFeed> attach() async {
    final feed = (await host.open())!;
    link.attached(feed);
    return feed;
  }

  group('the link', () {
    test('a link opening asks the settings again, on every link', () async {
      var attached = 0;
      link = HostCompanionLink(
        deviceById: (id) async => recorded[id],
        onAttached: () => attached++,
      );
      await attach();
      expect(attached, 1);
      link.detached();
      await attach();
      expect(attached, 2, reason: 'the host may be a new one');
    });

    test('asks the server over the link, and says so with no link', () async {
      await expectLater(
        link.serverCall(ServerMethod.configGet),
        throwsA(isA<StateError>()),
      );
      host.answerServerCall = (method, arguments) async => {
        'asked': method,
        ...arguments,
      };
      await attach();

      final answer = await link.serverCall(ServerMethod.configSet, {
        'patch': {'companion': <String, Object?>{}},
      });
      expect(answer['asked'], ServerMethod.configSet);
      expect(host.serverCalls.single.method, ServerMethod.configSet);
    });

    test('pairs through the host and reads the stored phone back', () async {
      final payload = await PairingPayload.generateWithCode(
        relay: Uri.parse('wss://relay.example.com'),
        hostId: DeviceId.parse('11111111222222223333333344444444'),
        capabilities: CapabilitySet.all,
      );
      host.answerPairing = (requestId) => PairedMessage(
        requestId: requestId,
        code: 'CODE',
        expiresAt: DateTime.utc(2026, 9, 25, 13),
        payload: payload.encode(),
      );
      await attach();

      final pairing = await link.pair(
        capabilities: CapabilitySet.all,
        relay: Uri.parse('wss://relay.example.com'),
      );
      expect(pairing.payload.encode(), payload.encode());
      expect(host.pairings.single.relay, 'wss://relay.example.com');

      recorded['pixel'] = device('pixel');
      host.companionEventLink.add(
        const CompanionEventMessage(
          CompanionEventKind.pairingEnded,
          requestId: 1,
          deviceId: 'pixel',
        ),
      );

      expect((await pairing.done).id, 'pixel');
    });

    test(
      'a pairing the host ended without a phone fails in its words',
      () async {
        final payload = await PairingPayload.generateWithCode(
          relay: Uri.parse('wss://relay.example.com'),
          hostId: DeviceId.parse('11111111222222223333333344444444'),
          capabilities: CapabilitySet.all,
        );
        host.answerPairing = (requestId) => PairedMessage(
          requestId: requestId,
          code: 'CODE',
          expiresAt: DateTime.utc(2026, 9, 25, 13),
          payload: payload.encode(),
        );
        await attach();
        final pairing = await link.pair(capabilities: CapabilitySet.all);

        host.companionEventLink.add(
          const CompanionEventMessage(
            CompanionEventKind.pairingEnded,
            requestId: 1,
            error: 'the code expired',
          ),
        );

        await expectLater(
          pairing.done,
          throwsA(
            isA<PairingException>().having(
              (e) => e.message,
              'message',
              'the code expired',
            ),
          ),
        );
      },
    );

    test('pairing with no link says the host is not running', () async {
      await expectLater(
        link.pair(capabilities: CapabilitySet.all),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('the controller, where the host serves the phones', () {
    late ProviderContainer container;
    late RemoteAccessController controller;
    late MemoryServerConfigSource server;
    late FakeDataServer data;

    setUp(() async {
      server = MemoryServerConfigSource();
      data = FakeDataServer();
      container = ProviderContainer(
        overrides: [
          await data.override(),
          companionAtHostProvider.overrideWithValue(true),
          hostCompanionLinkProvider.overrideWithValue(link),
          serverConfigIn(server),
        ],
      );
      controller = container.read(remoteAccessControllerProvider);
      await attach();
    });

    tearDown(() {
      container.dispose();
    });

    test('switching remote access on writes the server config — the LAN, '
        'the beacon, the PopupBits relay and what only the app knows — and '
        'runs no server of its own', () async {
      await controller.setRemoteAccess(enabled: true);

      final config = server.config;
      expect(config.companionEnabled, isTrue);
      expect(config.bind, '0.0.0.0');
      expect(config.beacon, isTrue);
      expect(config.relay, Uri.parse(kDefaultRelayUrl));
      expect(config.notes, isTrue);
      expect(config.extraRelays, isEmpty);
      expect(container.read(remoteAccessSettingsProvider).enabled, isTrue);

      await controller.setRemoteAccess(enabled: false);
      expect(server.config.companionEnabled, isFalse);
      expect(server.config.bind, '0.0.0.0', reason: 'the rest kept');
      expect(container.read(remoteAccessSettingsProvider).enabled, isFalse);
    });

    test('the internet relay and its switch are the server config', () async {
      await controller.setRemoteAccess(enabled: true);
      await controller.setRemoteAccess(relayUrl: 'wss://mine.example.com');
      expect(server.config.relay, Uri.parse('wss://mine.example.com'));

      await controller.setRemoteAccess(relayUrl: '');
      expect(server.config.relay, Uri.parse(kDefaultRelayUrl));

      await controller.setRemoteAccess(hostedEnabled: false);
      expect(server.config.relayEnabled, isFalse);
      expect(container.read(remoteAccessSettingsProvider).relayEnabled, false);
    });

    test('the local relay and its port are the server config: the app runs '
        'no relay of its own', () async {
      await controller.setRemoteAccess(enabled: true);
      expect(server.config.localRelay, isNull, reason: 'off until asked');

      await controller.setRemoteAccess(localRelay: true);
      expect(server.config.localRelay, isTrue);
      expect(container.read(remoteAccessSettingsProvider).localRelay, isTrue);

      await controller.setRemoteAccess(localRelayPort: 9797);
      expect(server.config.localRelayPort, 9797);
      expect(container.read(remoteAccessSettingsProvider).localRelayPort, 9797);

      await controller.setRemoteAccess(localRelay: false);
      expect(server.config.localRelay, isFalse);
    });

    test('a link attaching reads what the server serves by again', () async {
      server.config = ServerConfig(
        companionEnabled: true,
        relay: Uri.parse('wss://relay.example.com'),
        notes: true,
      );
      await controller.reload();

      final access = container.read(remoteAccessSettingsProvider);
      expect(access.enabled, isTrue);
      expect(access.relay, Uri.parse('wss://relay.example.com'));
      expect(server.patches, isEmpty, reason: 'nothing of the app\'s moved');
    });

    test('a revoke goes through the server, not a notice', () async {
      data.deviceRows.insert(device('pixel'));
      final notices = host.companionNotices.length;

      await controller.revoke(device('pixel'));

      expect(data.deviceRows.getById('pixel')!.revoked, isTrue);
      expect(data.deviceRows.applied, ['devices.revoke']);
      expect(host.companionNotices, hasLength(notices));
    });

    test('pairing asks the host, and only with remote access on', () async {
      await expectLater(
        controller.beginPairing(capabilities: CapabilitySet.all),
        throwsA(isA<StateError>()),
      );
      expect(host.pairings, isEmpty);
    });
  });
}
