/// "Each time i pair from the same phone, it's shown as a new device in the
/// list in the desktop app."
///
/// A phone used to mint a fresh [DeviceId] at every pairing, so the desktop —
/// which files devices by that id — met a stranger each time and kept the old
/// row for ever, holding a key nobody would ever use again. A phone has ONE
/// identity; a pairing refreshes its row.
///
/// The id proves nothing, and is not a secret: the sealed handshake is what
/// proves who is on the line. It is only the name the desktop files this
/// phone under.
@Tags(['cost'])
library;

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_remote/client.dart'
    as stored;
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late Map<String, String> phoneDisk;
  late SecureCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    phoneDisk = {
      RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
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
    await relay.close();
    db.close();
  });

  Future<RemoteHostService> startService() async {
    final started = service = RemoteHostService(
      devices: dao,
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
    );
    await started.start();
    return started;
  }

  RemoteCompanionGateway makeGateway({stored.CompanionStore? over}) {
    final gateway = RemoteCompanionGateway(
      store: over ?? store,
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

  Future<void> pair(RemoteCompanionGateway gateway) async {
    final session = await service!.beginPairing(capabilities: CapabilitySet.all);
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
  }

  test('pairing the same phone twice refreshes its row instead of adding a '
      'stranger', timeout: const Timeout(Duration(minutes: 2)), () async {
    await startService();
    final first = makeGateway();
    await pair(first);
    final before = dao.getAll().single;
    await first.close();

    // The owner's exact move: pair again from the same phone.
    final again = makeGateway();
    await pair(again);

    final rows = dao.getAll();
    expect(rows, hasLength(1), reason: 'one phone is one device row');
    final after = rows.single;
    expect(after.id, before.id, reason: 'the same phone, the same identity');
    expect(
      after.deviceKey,
      isNot(before.deviceKey),
      reason: 'a re-pair replaces the key material',
    );
    expect(after.createdAt, before.createdAt, reason: 'the row is the same row');
    expect(after.revoked, isFalse);
    // And it works: a fresh key, a fresh channel, a live link.
    expect((await again.listSessions()).single.id, 's1');
  });

  test('a re-paired phone keeps working over a genuinely fresh channel — no '
      'stale generation, no replay window', timeout: const Timeout(
    Duration(minutes: 2),
  ), () async {
    await startService();
    final first = makeGateway();
    await pair(first);
    // Run the link forward so the generation counter is well past its start.
    await first.listSessions();
    await first.close();

    final again = makeGateway();
    await pair(again);

    final row = dao.getAll().single;
    expect(
      row.generation,
      kFirstSessionGeneration,
      reason: 'a new key means a new rendezvous series, started from the top',
    );
    // The proof that nothing stale survived: real traffic, both ways.
    expect((await again.listSessions()).single.id, 's1');
    expect(
      (await again.transcript('s1').first),
      isA<List<CompanionChatMessage>>(),
    );
  });

  test('the phone keeps its identity across unpairing every desktop',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    await startService();
    final first = makeGateway();
    await pair(first);
    final id = dao.getAll().single.id;

    await first.unpair();
    expect(
      phoneDisk[stored.CompanionPairing.storeKey],
      isNull,
      reason: 'the pairing is gone',
    );
    await first.close();

    final again = makeGateway();
    await pair(again);

    expect(dao.getAll(), hasLength(1));
    expect(
      dao.getAll().single.id,
      id,
      reason: 'the identity outlives every pairing that used it',
    );
  });

  test('a phone that paired before the id was stored adopts the id it '
      'already had', timeout: const Timeout(Duration(minutes: 2)), () async {
    await startService();
    final first = makeGateway();
    await pair(first);
    final id = dao.getAll().single.id;
    await first.close();

    // Exactly what an existing phone's keystore looks like: pairing records,
    // and no device-id key at all.
    phoneDisk.remove(RemoteCompanionGateway.kDeviceIdStoreKey);

    final again = makeGateway();
    await pair(again);

    expect(
      dao.getAll(),
      hasLength(1),
      reason: 'no final duplicate for a phone that already has an identity',
    );
    expect(dao.getAll().single.id, id);
    expect(phoneDisk[RemoteCompanionGateway.kDeviceIdStoreKey], id);
  });

  test('two genuinely different phones are still two devices', timeout: const
      Timeout(Duration(minutes: 2)), () async {
    await startService();
    final mine = makeGateway();
    await pair(mine);

    // A second phone: its own keystore, its own everything.
    final otherDisk = <String, String>{
      RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
    };
    final theirs = makeGateway(
      over: SecureCompanionStore.withBackend(
        read: (key) async => otherDisk[key],
        write: (key, value) async => otherDisk[key] = value,
        delete: (key) async => otherDisk.remove(key),
      ),
    );
    await pair(theirs);

    expect(dao.getAll(), hasLength(2));
    expect(
      {for (final row in dao.getAll()) row.id},
      hasLength(2),
      reason: 'two phones, two identities',
    );
  });
}
