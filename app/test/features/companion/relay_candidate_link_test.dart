/// Loop 83 where it actually has to hold: the real [RemoteCompanionGateway]
/// against a real [RemoteHostService] over TWO in-process relays, so the
/// candidate set is proven by sockets rather than by a policy function.
///
/// Three promises, one per test: a relay that has gone away costs a phone a
/// couple of seconds, not a re-pairing; a relay switched on later reaches the
/// phone over the live link; and a desktop whose LAN address moved retires the
/// address it used to have.
///
/// Safe because a relay is a **meeting place, never an identity** — the
/// rendezvous is HKDF-derived from the device key and every frame is sealed
/// under it, so the second relay in a set is met by exactly the phone that
/// holds the key, and nobody else.
library;

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/core/server/secure_machine_store.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart' as stored;
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

void main() {
  late MemoryPairedDeviceStore dao;
  late FakeRemoteBindings fake;

  /// Two in-process relays on ephemeral ports — never 8787. [hosted] stands
  /// in for the internet one, [local] for the desktop's embedded relay.
  late RelayServer hosted;
  late RelayServer local;
  late Uri hostedUri;
  late Uri localUri;
  var hostedClosed = false;

  RemoteHostService? service;
  late Map<String, String> phoneDisk;
  late SecureCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];

  setUp(() async {
    dao = MemoryPairedDeviceStore();
    fake = FakeRemoteBindings()..addSession('s1');
    hosted = await RelayServer.bind(address: '127.0.0.1', port: 0);
    local = await RelayServer.bind(address: '127.0.0.1', port: 0);
    hostedClosed = false;
    hostedUri = Uri.parse('http://127.0.0.1:${hosted.port}');
    localUri = Uri.parse('http://127.0.0.1:${local.port}');
    phoneDisk = {
      // The last resort of the dial order is the phone's CONFIGURED relay,
      // which defaults to the build's hosted one. Point it at this suite's
      // hosted stand-in so no test ever reaches the internet.
      RemoteCompanionGateway.kPairingRelayStoreKey: hostedUri.toString(),
    };
    store = SecureCompanionStore.withBackend(
      read: (key) async => phoneDisk[key],
      write: (key, value) async => phoneDisk[key] = value,
      delete: (key) async => phoneDisk.remove(key),
    );
  });

  tearDown(() async {
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    await service?.stop();
    service = null;
    if (!hostedClosed) await hosted.close();
    await local.close();
  });

  Future<RemoteHostService> startService({Uri? localRelayUrl}) async {
    final started = service = RemoteHostService(
      devices: dao,
      hostId: DeviceId.parse('11111111222222223333333344444444'),
      bindings: fake.bindings,
      relay: hostedUri,
      localRelayUrl: localRelayUrl,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    await started.start();
    return started;
  }

  RemoteCompanionGateway makeGateway() {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Test phone',
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
      requestTimeout: const Duration(seconds: 2),
      helloTimeout: const Duration(seconds: 2),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  Future<void> awaitLink(
    RemoteCompanionGateway gateway,
    CompanionLinkState wanted,
  ) => gateway.linkStates
      .firstWhere((state) => state == wanted)
      .timeout(const Duration(seconds: 60));

  Future<void> pairPhone(RemoteCompanionGateway gateway) async {
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
  }

  /// The record as it sits on the phone's "disk", read back through the real
  /// store — never the gateway's in-memory copy.
  Future<stored.CompanionPairing> saved() async =>
      (await stored.CompanionConnections.load(store)).active!;

  Future<List<Uri>> savedRelays() async => [
    for (final candidate in (await saved()).candidates) candidate.url,
  ];

  /// What the host should be announcing as its direct LAN address.
  String lanHint(String address) => '$address:${service!.lanPortBound}';

  Future<void> eventually(
    Future<bool> Function() check, {
    Duration timeout = const Duration(seconds: 10),
    String reason = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await check()) return;
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test(
    'a relay that went away costs a reconnect, not a re-pairing: the next '
    'candidate answers',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService(localRelayUrl: localUri);
      final first = makeGateway();
      await pairPhone(first);

      // Pairing left the phone with the whole set, not just the tab it scanned.
      expect(await savedRelays(), containsAll(<Uri>[hostedUri, localUri]));
      expect(first.activeRelay, hostedUri);
      final device = dao.getAll().single;
      await first.close();

      // The relay the phone knows best simply stops existing — an outage, or an
      // internet the phone no longer has.
      await hosted.close();
      hostedClosed = true;

      final second = makeGateway();
      await awaitLink(second, CompanionLinkState.connected);

      // It fell through to the other saved candidate and is fully working.
      expect(second.activeRelay, localUri);
      expect((await second.listSessions()).single.id, 's1');
      // The same device row, the same key: nothing was re-paired.
      expect(dao.getAll().single.id, device.id);
      expect(dao.getAll().single.deviceKey, device.deviceKey);

      final record = await saved();
      final dead = record.candidates.firstWhere((c) => c.url == hostedUri);
      final live = record.candidates.firstWhere((c) => c.url == localUri);
      expect(
        dead.lastFailureAt,
        isNotNull,
        reason: 'the dead relay is stamped',
      );
      expect(dead.inCooldown(DateTime.now().toUtc()), isTrue);
      expect(live.lastSuccessAt, isNotNull, reason: 'the winner is last-good');
      // And the legacy single-relay mirror follows the relay actually in use,
      // so even a downgraded build would now dial the one that works.
      expect(record.relay, localUri);
    },
  );

  test(
    'a relay switched on later reaches the phone over the live link — no '
    're-pairing',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // A desktop serving the hosted relay only: exactly the shape that used to
      // strand a phone when the owner turned the local relay on afterwards.
      await startService();
      final gateway = makeGateway();
      await pairPhone(gateway);
      expect(await savedRelays(), [hostedUri]);

      await service!.updateRelays(localRelayUrl: localUri, hostedEnabled: true);

      await eventually(
        () async => (await savedRelays()).contains(localUri),
        reason: 'the phone learns the new relay from host.status',
      );
      expect(await savedRelays(), containsAll(<Uri>[hostedUri, localUri]));
      // The link never dropped and the desktop never asked for a new pairing.
      expect(gateway.link, CompanionLinkState.connected);
      expect(gateway.activeRelay, hostedUri);
      expect(dao.getAll(), hasLength(1));
      expect((await gateway.listSessions()).single.id, 's1');
    },
  );

  test(
    'a desktop whose LAN address moved retires the address it used to '
    'have',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // The embedded relay as the desktop advertises it: a LAN URL, which is
      // exactly what DHCP is free to change under a paired phone.
      final was = Uri.parse('ws://192.168.5.9:${local.port}');
      final now = Uri.parse('ws://192.168.5.20:${local.port}');
      await startService(localRelayUrl: was);
      final gateway = makeGateway();
      await pairPhone(gateway);
      // The greeting lands just after the link comes up — the phone is usable
      // first and better-informed a moment later.
      await eventually(
        () async => (await saved()).lanHint == lanHint('192.168.5.9'),
        reason: 'the LAN relay and its hint are saved',
      );
      expect(await savedRelays(), contains(was));

      await service!.updateRelays(localRelayUrl: now, hostedEnabled: true);

      await eventually(
        () async => (await savedRelays()).contains(now),
        reason: 'the moved address arrives',
      );
      // The stale one is gone rather than kept forever: an announcement is the
      // truth about where the host is, not an addition to it.
      expect(await savedRelays(), isNot(contains(was)));
      expect(await savedRelays(), contains(hostedUri));
      expect((await saved()).lanHint, lanHint('192.168.5.20'));
      expect(gateway.link, CompanionLinkState.connected);
    },
  );
}
