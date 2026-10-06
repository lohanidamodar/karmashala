/// A pairing moves from a retired relay to the current one without a
/// re-pair, end to end over real sockets and two in-process relays: the host
/// announces `link.relay.move` to a phone whose hello says it knows the frame,
/// the phone saves it, acknowledges with `link.relay.moved` and dials the new
/// relay, and the host switches its row on the ack. Nobody is stranded on the
/// way: a lost ack, a phone that never acknowledges, and the window while the
/// phone has not yet shown up on the new relay all still connect.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x41 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late RelayServer oldRelay;
  late RelayServer newRelay;
  late RelayServer otherRelay;
  late Uri oldUri;
  late Uri newUri;
  late Uri otherUri;
  RemoteHostService? service;
  final links = <SealedHostLink>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    links.clear();
    oldRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    newRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    otherRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    oldUri = Uri.parse('http://127.0.0.1:${oldRelay.port}');
    newUri = Uri.parse('http://127.0.0.1:${newRelay.port}');
    otherUri = Uri.parse('http://127.0.0.1:${otherRelay.port}');
  });

  tearDown(() async {
    await service?.stop();
    service = null;
    await oldRelay.close();
    await newRelay.close();
    await otherRelay.close();
    db.close();
  });

  Future<Uint8List> deviceKey() async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: _deviceId,
    )).bytes,
  );

  Future<void> pair(String relayUrl) async => dao.insert(
    PairedDevice(
      id: _deviceId.value,
      name: 'pixel',
      deviceKey: await deviceKey(),
      capabilities: CapabilitySet.of([Capability.phoneClient]),
      generation: kFirstSessionGeneration,
      createdAt: DateTime.utc(2026, 10, 6),
      relayUrl: relayUrl,
    ),
  );

  RemoteTransport relayTransport(Uri relay, RendezvousId rendezvous) =>
      RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start();

  /// The server is configured with the old relay, as an install that enabled
  /// remote access before the move is: the policy reads it as the new one.
  Future<RemoteHostService> start({Uri? local}) async {
    final started = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: FakeRemoteBindings().bindings,
      relay: oldUri,
      localRelayUrl: local,
      knownRelays: KnownRelays(current: newUri, retired: [oldUri]),
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: relayTransport,
      onHostLink: (link) {
        links.add(link);
        link.incoming.listen(link.add);
      },
    );
    service = started;
    await started.start();
    return started;
  }

  Future<CompanionPairing> record(Uri relay, {Uri? home}) async =>
      CompanionPairing(
        hostId: _hostId,
        deviceId: _deviceId,
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.of([Capability.phoneClient]),
        relay: relay,
        relayHome: home,
        generation: dao.getById(_deviceId.value)!.generation,
        hostName: 'desk',
      );

  /// Every relay the phone dialled, in order.
  final dialled = <Uri>[];

  DesktopServerDialer dialer(
    CompanionStore store, {
    bool acceptRelayMove = true,
  }) => DesktopServerDialer(
    store: store,
    acceptRelayMove: acceptRelayMove,
    relayFactory: (relay, rendezvous) {
      dialled.add(relay);
      return relayTransport(relay, rendezvous);
    },
  );

  setUp(dialled.clear);

  Future<void> echoes(SealedHostLink link) async {
    final got = Completer<List<int>>();
    final sub = link.incoming.listen((bytes) {
      if (!got.isCompleted) got.complete(bytes);
    });
    link.add(Uint8List.fromList([4, 2]));
    expect(await got.future.timeout(const Duration(seconds: 10)), [4, 2]);
    await sub.cancel();
  }

  Set<String> listening() => {
    for (final url in service!.activeRelayUrlsFor(
      dao.getById(_deviceId.value)!,
    ))
      url.toString(),
  };

  test('new pairings use the current relay even when the config still names '
      'the retired one', () async {
    final host = await start();
    expect(host.relay, newUri);
    final pairing = await host.beginPairing(capabilities: CapabilitySet.all);
    expect(pairing.payload.relay, newUri);
  });

  test('the move, both sides: announced on the old relay, saved and '
      'acknowledged, the row switched, and the phone served on the new '
      'relay — after which the old one is let go', () async {
    await pair(oldUri.toString());
    await start();
    expect(listening(), containsAll([oldUri.toString(), newUri.toString()]));
    final store = InMemoryCompanionStore();
    await CompanionConnections.mutate(store, (all) async {
      all.upsert(await record(oldUri));
    });

    final link = await dialer(store).dial(await record(oldUri));
    addTearDown(() => link.close());
    await echoes(link);

    expect(dialled.map((u) => u.toString()), [
      oldUri.toString(),
      newUri.toString(),
    ]);
    final row = dao.getById(_deviceId.value)!;
    expect(row.relayUrl, newUri.toString());
    expect(row.relayMovedFrom, oldUri.toString());
    expect(row.relayMoveSettled, isTrue, reason: 'heard on the new relay');
    expect(listening(), {newUri.toString()});

    final saved = (await CompanionConnections.load(
      store,
    )).byHost(_hostId.value)!;
    expect(saved.relayHome, newUri);
    expect(saved.relay, newUri);
  });

  test('a lost ack: the phone saved the move but the host never heard it — '
      'the phone dials its saved relay first, the host is waiting there, '
      'and the move completes', () async {
    await pair(oldUri.toString());
    await start();
    final store = InMemoryCompanionStore();
    final saved = await record(oldUri, home: newUri);
    await saved.save(store);

    final link = await dialer(store).dial(saved);
    addTearDown(() => link.close());
    await echoes(link);

    expect(dialled.first, newUri, reason: 'its saved relay first');
    final row = dao.getById(_deviceId.value)!;
    expect(row.relayUrl, newUri.toString());
    expect(row.relayMoveSettled, isTrue);
  });

  test('mid-move: the row switched, but the phone comes back on the old '
      'relay — the host still listens there, and moves it again', () async {
    await pair(oldUri.toString());
    dao.moveRelay(_deviceId.value, newUri.toString());
    await start();
    expect(listening(), containsAll([oldUri.toString(), newUri.toString()]));

    final store = InMemoryCompanionStore();
    final link = await dialer(store).dial(await record(oldUri));
    addTearDown(() => link.close());
    await echoes(link);

    expect(dialled.last, newUri);
    expect(dao.getById(_deviceId.value)!.relayMoveSettled, isTrue);
  });

  test('mid-move with the new relay unreachable: the phone falls back to the '
      'old relay and is served there, the move left open', () async {
    // Nothing listens on port 1: the relay the row moved to cannot be reached.
    final unreachable = Uri.parse('http://127.0.0.1:1');
    await pair(oldUri.toString());
    dao.moveRelay(_deviceId.value, unreachable.toString());
    await start();

    final store = InMemoryCompanionStore();
    final link = await dialer(store).dial(await record(oldUri));
    addTearDown(() => link.close());
    await echoes(link);

    final row = dao.getById(_deviceId.value)!;
    expect(row.relayMoveSettled, isFalse);
    expect(listening(), contains(oldUri.toString()));
  });

  test('an old phone, whose hello does not know the frame, is never sent '
      'it: it stays on the old relay and the row is untouched', () async {
    await pair(oldUri.toString());
    await start();
    final store = InMemoryCompanionStore();

    final link = await dialer(
      store,
      acceptRelayMove: false,
    ).dial(await record(oldUri));
    addTearDown(() => link.close());
    await echoes(link);

    expect(dialled, [oldUri]);
    final row = dao.getById(_deviceId.value)!;
    expect(row.relayUrl, oldUri.toString());
    expect(row.relayMovedFrom, isNull);
    expect(listening(), containsAll([oldUri.toString(), newUri.toString()]));
    final saved = (await CompanionConnections.load(
      store,
    )).byHost(_hostId.value)!;
    expect(saved.relayHome, isNull);
  });

  test('a self-hosted relay is never moved', () async {
    await pair(otherUri.toString());
    await start();
    final store = InMemoryCompanionStore();

    final link = await dialer(store).dial(await record(otherUri));
    addTearDown(() => link.close());
    await echoes(link);

    expect(dialled, [otherUri]);
    expect(dao.getById(_deviceId.value)!.relayUrl, otherUri.toString());
    expect(dao.getById(_deviceId.value)!.relayMovedFrom, isNull);
  });

  test('a pairing on the local relay is never moved', () async {
    await pair(kLocalRelayMarker);
    await start(local: otherUri);
    final store = InMemoryCompanionStore();

    final link = await dialer(store).dial(await record(otherUri));
    addTearDown(() => link.close());
    await echoes(link);

    expect(dialled, [otherUri]);
    expect(dao.getById(_deviceId.value)!.relayUrl, kLocalRelayMarker);
    expect(dao.getById(_deviceId.value)!.relayMovedFrom, isNull);
  });
}
