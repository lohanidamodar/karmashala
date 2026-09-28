/// A desktop client's sealed channel switched to the host protocol (slice
/// 5e), end to end over real sockets on 127.0.0.1 and an in-process relay:
/// the grant it needs, bytes both ways in order and in pieces, and a dropped
/// socket that ends the byte stream and moves the generation on.
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
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x31 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late RelayServer relay;
  late Uri relayUri;
  late RemoteHostService service;
  final links = <SealedHostLink>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    links.clear();
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
  });

  tearDown(() async {
    await service.stop();
    await relay.close();
    db.close();
  });

  Future<Uint8List> deviceKey() async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: _deviceId,
    )).bytes,
  );

  Future<void> pair(CapabilitySet grants) async => dao.insert(
    PairedDevice(
      id: _deviceId.value,
      name: 'studio-mac',
      deviceKey: await deviceKey(),
      capabilities: grants,
      generation: kFirstSessionGeneration,
      createdAt: DateTime.utc(2026, 9, 27),
      relayUrl: relayUri.toString(),
    ),
  );

  /// The host end echoes every byte back, so the test reads its own writes.
  Future<void> start() async {
    service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: FakeRemoteBindings().bindings,
      relay: relayUri,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
      onHostLink: (link) {
        links.add(link);
        link.incoming.listen(link.add);
      },
    );
    await service.start();
  }

  Future<CompanionPairing> record({String? direct}) async => CompanionPairing(
    hostId: _hostId,
    deviceId: _deviceId,
    deviceKey: await deviceKey(),
    capabilities: CapabilitySet.of([Capability.desktopClient]),
    relay: relayUri,
    generation: kFirstSessionGeneration,
    hostName: 'droplet',
    directEndpoint: direct,
  );

  Future<List<int>> echo(SealedHostLink link, List<int> bytes) async {
    final got = <int>[];
    final done = Completer<void>();
    final sub = link.incoming.listen((chunk) {
      got.addAll(chunk);
      if (got.length >= bytes.length && !done.isCompleted) done.complete();
    });
    link.add(Uint8List.fromList(bytes));
    await done.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    return got;
  }

  test('over the LAN: the switch is answered, and 2 MiB crosses in order, '
      'sealed in pieces under the relay\'s frame', () async {
    await pair(CapabilitySet.of([Capability.desktopClient]));
    await start();
    final store = InMemoryCompanionStore();
    final dialer = DesktopServerDialer(store: store);
    final link = await dialer.dial(
      await record(direct: '127.0.0.1:${service.lanPortBound}'),
    );
    addTearDown(() => link.close());
    final big = List<int>.generate(2 * 1024 * 1024, (i) => i % 251);
    expect(await echo(link, big), big);
    expect(links.single.deviceName, 'studio-mac');
    // The counter moved on, so the next link is a fresh generation.
    final saved = await CompanionPairing.load(store);
    expect(saved!.generation, kFirstSessionGeneration + 1);
  });

  test('over the relay, when no address was typed', () async {
    await pair(CapabilitySet.of([Capability.desktopClient]));
    await start();
    final link = await DesktopServerDialer(
      store: InMemoryCompanionStore(),
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
      )..start(),
    ).dial(await record());
    addTearDown(() => link.close());
    expect(await echo(link, [1, 2, 3]), [1, 2, 3]);
  });

  test('a phone\'s pairing may not switch: refused in words, no link '
      'served', () async {
    await pair(CapabilitySet.all);
    await start();
    await expectLater(
      DesktopServerDialer(store: InMemoryCompanionStore()).dial(
        await record(direct: '127.0.0.1:${service.lanPortBound}'),
      ),
      throwsA(
        isA<DesktopConnectException>()
            .having((e) => e.refused, 'refused', isTrue)
            .having((e) => e.message, 'message', contains('desktop')),
      ),
    );
    expect(links, isEmpty);
  });

  test('a dropped socket ends the byte stream at both ends, and the next '
      'dial is served on the next generation', () async {
    await pair(CapabilitySet.of([Capability.desktopClient]));
    await start();
    final store = InMemoryCompanionStore();
    final dialer = DesktopServerDialer(store: store);
    final first = await dialer.dial(
      await record(direct: '127.0.0.1:${service.lanPortBound}'),
    );
    expect(await echo(first, [7]), [7]);
    first.close('gone');
    await links.single.done.timeout(const Duration(seconds: 10));

    final again = (await CompanionPairing.load(store))!;
    final second = await dialer.dial(again);
    addTearDown(() => second.close());
    expect(await echo(second, [8, 9]), [8, 9]);
    expect(links, hasLength(2));
    expect(dao.getById(_deviceId.value)!.generation, greaterThan(1));
  });
}
