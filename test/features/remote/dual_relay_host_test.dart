/// The owner's ask, proven end to end: one desktop serving **two phones on
/// two different relays at the same time** — one paired through the embedded
/// local relay, one through a hosted one — over real sockets on 127.0.0.1.
///
/// Also the park/return contract: switching a relay off quiets exactly its own
/// devices (no crash loop, no re-pair, no generation change) and switching it
/// back on picks them up again.
library;

import 'dart:typed_data';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala/src/features/remote/client/companion_client.dart';
import 'package:karmashala/src/features/remote/client/companion_pairing_client.dart';
import 'package:karmashala/src/features/remote/client/companion_store.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala/src/features/remote/domain/paired_device.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_payload.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/remote/transport/key_schedule.dart';
import 'package:karmashala/src/features/remote/transport/relay_transport.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _localPhone = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _hostedPhone = DeviceId.parse('eeeeeeeeffffffff0000000011111111');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;

  /// Two in-process relays: one standing in for the embedded local one, one
  /// for a hosted one. Ephemeral ports — never 8787.
  late RelayServer localRelay;
  late RelayServer hostedRelay;
  late Uri localUri;
  late Uri hostedUri;
  late RemoteHostService service;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    localRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    hostedRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    localUri = Uri.parse('http://127.0.0.1:${localRelay.port}');
    hostedUri = Uri.parse('http://127.0.0.1:${hostedRelay.port}');
  });

  tearDown(() async {
    for (final cleanup in cleanups.reversed.toList()) {
      await cleanup();
    }
    cleanups.clear();
    await service.stop();
    await localRelay.close();
    await hostedRelay.close();
    db.close();
  });

  Future<Uint8List> keyFor(DeviceId deviceId) async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: deviceId,
    )).bytes,
  );

  Future<void> pair(DeviceId deviceId, {required String relayUrl}) async {
    dao.insert(
      PairedDevice(
        id: deviceId.value,
        name: 'phone-${deviceId.value.substring(0, 4)}',
        deviceKey: await keyFor(deviceId),
        capabilities: CapabilitySet.all,
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 8, 31),
        relayUrl: relayUrl,
      ),
    );
  }

  Future<void> startService({
    bool hostedEnabled = true,
    bool localEnabled = true,
    Uri? local,
  }) async {
    service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: fake.bindings,
      relay: hostedUri,
      localRelayUrl: localEnabled ? (local ?? localUri) : null,
      hostedEnabled: hostedEnabled,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    await service.start();
  }

  Future<CompanionClient> clientFor(
    DeviceId deviceId, {
    required Uri relay,
    int? generation,
  }) async {
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: deviceId,
        deviceKey: await keyFor(deviceId),
        capabilities: CapabilitySet.all,
        relay: relay,
        generation: generation ?? dao.getById(deviceId.value)!.generation,
        hostName: 'TestHost',
      ),
      store: InMemoryCompanionStore(),
      requestTimeout: const Duration(seconds: 5),
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    cleanups.add(client.close);
    return client;
  }

  test('two phones, two relays, one desktop — both served at once', () async {
    await pair(_localPhone, relayUrl: kLocalRelayMarker);
    await pair(_hostedPhone, relayUrl: hostedUri.toString());
    await startService();

    final onLocal = await clientFor(_localPhone, relay: localUri);
    final onHosted = await clientFor(_hostedPhone, relay: hostedUri);

    // Both connect concurrently — neither relay is a queue for the other.
    final statuses = await Future.wait([
      onLocal.connect(helloTimeout: const Duration(seconds: 5)),
      onHosted.connect(helloTimeout: const Duration(seconds: 5)),
    ]);
    expect(statuses.map((s) => s.hostName), ['TestHost', 'TestHost']);

    // And both get real service, at the same time, from the same desktop.
    final lists = await Future.wait([
      onLocal.listSessions(),
      onHosted.listSessions(),
    ]);
    expect([for (final rows in lists) rows.single.sessionId], ['s1', 's1']);

    await onLocal.sendPrompt('s1', 'from the local phone');
    await onHosted.sendPrompt('s1', 'from the hosted phone');
    expect(fake.prompts, [
      (sessionId: 's1', text: 'from the local phone'),
      (sessionId: 's1', text: 'from the hosted phone'),
    ]);
  });

  test('one device, both relays: whichever it reaches, the host is '
      'waiting there', () async {
    // Loop 83 replaces Loop 80's one-listener-per-device topology. The phone
    // now picks its own path from a saved candidate set, so the host waits on
    // EVERY active relay — including the one this device did not pair on.
    await pair(_localPhone, relayUrl: kLocalRelayMarker);
    await startService();

    // The relay it never paired on serves it anyway. Safe by construction:
    // the rendezvous comes from the device key, so only the phone holding
    // that key can meet the host here.
    final onHosted = await clientFor(_localPhone, relay: hostedUri);
    expect(
      (await onHosted.connect(helloTimeout: const Duration(seconds: 5)))
          .hostName,
      'TestHost',
    );
    expect((await onHosted.listSessions()).single.sessionId, 's1');

    // And the relay it did pair on is still there — WITHOUT tearing the first
    // link down, so both listeners are proven open at the same moment. (One
    // device still has one live sealed link: a real phone dials one candidate
    // at a time, and the host keeps one active channel per device.) The next
    // session takes the next generation, exactly as a real companion's counter
    // bump does — the relay it arrives on changes nothing about the schedule.
    final onLocal = await clientFor(
      _localPhone,
      relay: localUri,
      generation: kFirstSessionGeneration + 1,
    );
    expect(
      (await onLocal.connect(helloTimeout: const Duration(seconds: 5)))
          .hostName,
      'TestHost',
    );
    expect((await onLocal.listSessions()).single.sessionId, 's1');
    final row = dao.getById(_localPhone.value)!;
    expect(row.revoked, isFalse);
    expect(row.deviceKey, isNotEmpty);
  });

  test('switching the local relay off leaves its device reachable on the '
      'hosted one — no re-pair, no parking', () async {
    await pair(_localPhone, relayUrl: kLocalRelayMarker);
    await pair(_hostedPhone, relayUrl: hostedUri.toString());
    await startService();
    final hosted = await clientFor(_hostedPhone, relay: hostedUri);
    await hosted.connect(helloTimeout: const Duration(seconds: 5));

    await service.updateRelays(localRelayUrl: null, hostedEnabled: true);

    // Neither device is parked: a relay is still up, and both are served on it.
    expect(service.isParked(_localPhone.value), isFalse);
    expect(service.isParked(_hostedPhone.value), isFalse);
    // The local relay's own listeners are gone…
    final gone = await clientFor(_localPhone, relay: localUri);
    await expectLater(
      gone.connect(helloTimeout: const Duration(milliseconds: 700)),
      throwsA(isA<RemoteApiException>()),
    );
    // …but the phone that lost its relay simply meets the host on the other.
    final rerouted = await clientFor(_localPhone, relay: hostedUri);
    expect(
      (await rerouted.connect(helloTimeout: const Duration(seconds: 5)))
          .hostName,
      'TestHost',
    );
    // And the phone that never moved noticed nothing.
    expect((await hosted.listSessions()).single.sessionId, 's1');
    final row = dao.getById(_localPhone.value)!;
    expect(row.revoked, isFalse);
    expect(row.deviceKey, isNotEmpty);
  });

  test('parking needs EVERY relay off, and a relay coming back un-parks — '
      'no re-pair', () async {
    await pair(_localPhone, relayUrl: kLocalRelayMarker);
    await startService();

    await service.updateRelays(localRelayUrl: null, hostedEnabled: false);
    expect(service.isParked(_localPhone.value), isTrue);
    // Parking is not revocation: the row keeps its key and its generation.
    final parkedRow = dao.getById(_localPhone.value)!;
    expect(parkedRow.revoked, isFalse);
    expect(parkedRow.deviceKey, isNotEmpty);
    expect(parkedRow.generation, kFirstSessionGeneration);

    await service.updateRelays(localRelayUrl: localUri, hostedEnabled: false);

    expect(service.isParked(_localPhone.value), isFalse);
    final phone = await clientFor(_localPhone, relay: localUri);
    final status = await phone.connect(
      helloTimeout: const Duration(seconds: 5),
    );
    expect(status.hostName, 'TestHost');
    expect((await phone.listSessions()).single.sessionId, 's1');
  });

  test('switching the hosted relay off leaves every device on the local '
      'one', () async {
    await pair(_localPhone, relayUrl: kLocalRelayMarker);
    await pair(_hostedPhone, relayUrl: hostedUri.toString());
    await startService();

    await service.updateRelays(localRelayUrl: localUri, hostedEnabled: false);

    expect(service.isParked(_hostedPhone.value), isFalse);
    expect(service.isParked(_localPhone.value), isFalse);
    final local = await clientFor(_localPhone, relay: localUri);
    await local.connect(helloTimeout: const Duration(seconds: 5));
    expect((await local.listSessions()).single.sessionId, 's1');
    // The hosted-paired phone, whose own relay just went away, is met on the
    // local one instead — the candidate set is what makes that reachable.
    final stranded = await clientFor(_hostedPhone, relay: localUri);
    expect(
      (await stranded.connect(helloTimeout: const Duration(seconds: 5)))
          .hostName,
      'TestHost',
    );
  });

  test('host.status announces every active relay and the LAN hint', () async {
    await pair(_hostedPhone, relayUrl: hostedUri.toString());
    // A LAN address for the local relay is what the LAN hint is derived from.
    final lanish = Uri.parse('ws://192.168.5.9:${localRelay.port}');
    await startService(local: lanish);

    final phone = await clientFor(_hostedPhone, relay: hostedUri);
    final status = await phone.connect(
      helloTimeout: const Duration(seconds: 5),
    );

    expect(status.relays, containsAll(<Uri>[lanish, hostedUri]));
    expect(status.lanHint, startsWith('192.168.5.9:'));
  });

  test('a relay switched on under a live link is announced at once', () async {
    await pair(_hostedPhone, relayUrl: hostedUri.toString());
    await startService(localEnabled: false);
    final phone = await clientFor(_hostedPhone, relay: hostedUri);
    final first = await phone.connect(
      helloTimeout: const Duration(seconds: 5),
    );
    expect(first.relays, [hostedUri]);
    final announcements = phone.events
        .where((event) => event is HostStatusEvent)
        .cast<HostStatusEvent>()
        .map((event) => event.status)
        .first;

    await service.updateRelays(localRelayUrl: localUri, hostedEnabled: true);

    final refreshed = await announcements.timeout(const Duration(seconds: 5));
    expect(refreshed.relays, containsAll(<Uri>[localUri, hostedUri]));
  });

  test('the QR carries every active relay, and the tab stays first', () async {
    await startService();

    final session = await service.beginPairing(
      capabilities: CapabilitySet.all,
      relay: hostedUri,
    );

    expect(session.payload.relay, hostedUri);
    expect(session.payload.relays.first, hostedUri);
    expect(session.payload.relays, containsAll(<Uri>[hostedUri, localUri]));
    // And it survives the QR text an old build would read as one relay.
    final decoded = PairingPayload.decode(session.payload.encode());
    expect(decoded.relay, hostedUri);
    expect(decoded.relays, session.payload.relays);
  });

  test('a device paired before v19 falls back to the configured hosted '
      'relay', () async {
    // The v19 backfill writes a URL for every existing row; a row that
    // somehow has none must still be served, not silently parked forever.
    await pair(_hostedPhone, relayUrl: hostedUri.toString());
    db.execute('UPDATE paired_devices SET relay_url = NULL;');
    await startService();

    final phone = await clientFor(_hostedPhone, relay: hostedUri);
    final status = await phone.connect(
      helloTimeout: const Duration(seconds: 5),
    );
    expect(status.hostName, 'TestHost');
  });

  test('pairing stamps the relay the dialog chose', () async {
    await startService();
    final session = await service.beginPairing(
      capabilities: CapabilitySet.all,
      relay: localUri,
      relayIsLocal: true,
    );
    final store = InMemoryCompanionStore();
    final phone = CompanionPairingClient(store: store, deviceName: 'Scanner');
    await phone.pair(session.payload);
    final paired = await session.done;

    final row = dao.getById(paired.id)!;
    expect(row.pairedViaLocalRelay, isTrue);
    // The marker, never the LAN URL of the moment — the IP and port move.
    expect(row.relayUrl, kLocalRelayMarker);
  });

  test('pairing on the hosted tab stamps that relay URL', () async {
    await startService();
    final session = await service.beginPairing(
      capabilities: CapabilitySet.all,
      relay: hostedUri,
    );
    final store = InMemoryCompanionStore();
    final phone = CompanionPairingClient(store: store, deviceName: 'Scanner');
    await phone.pair(session.payload);
    final paired = await session.done;

    final row = dao.getById(paired.id)!;
    expect(row.pairedViaLocalRelay, isFalse);
    expect(row.hostedRelayUri, hostedUri);
  });
}
