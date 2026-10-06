/// Which route a desktop client's link is on now, as the link itself knows
/// it: the relay a dial landed on, none for an address on this network, and
/// the new relay when a dropped link resumes somewhere else. End to end over
/// two in-process relays and the server's LAN listener on 127.0.0.1.
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
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x71 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late RelayServer first;
  late RelayServer second;
  late Uri firstUri;
  late Uri secondUri;
  RemoteHostService? service;

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    first = await RelayServer.bind(address: '127.0.0.1', port: 0);
    second = await RelayServer.bind(address: '127.0.0.1', port: 0);
    firstUri = Uri.parse('http://127.0.0.1:${first.port}');
    secondUri = Uri.parse('http://127.0.0.1:${second.port}');
  });

  tearDown(() async {
    await service?.stop();
    service = null;
    await first.close();
    await second.close();
    db.close();
  });

  Future<Uint8List> deviceKey() async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: _deviceId,
    )).bytes,
  );

  RemoteTransport relayTransport(Uri relay, RendezvousId rendezvous) =>
      RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start();

  Future<RemoteHostService> start() async {
    dao.insert(
      PairedDevice(
        id: _deviceId.value,
        name: 'pixel',
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.of([Capability.desktopClient]),
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 10, 6),
        relayUrl: firstUri.toString(),
      ),
    );
    final started = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: FakeRemoteBindings().bindings,
      relay: firstUri,
      extraRelays: [secondUri],
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: relayTransport,
      onHostLink: (link) => link.incoming.listen(link.add),
    );
    service = started;
    await started.start();
    return started;
  }

  Future<(DesktopServerDialer, CompanionPairing)> saved({
    String? direct,
  }) async {
    final store = InMemoryCompanionStore();
    final pairing = CompanionPairing(
      hostId: _hostId,
      deviceId: _deviceId,
      deviceKey: await deviceKey(),
      capabilities: CapabilitySet.of([Capability.desktopClient]),
      relay: firstUri,
      candidates: [
        RelayCandidate(url: firstUri),
        RelayCandidate(url: secondUri),
      ],
      generation: kFirstSessionGeneration,
      hostName: 'desk',
      directEndpoint: direct,
    );
    await pairing.save(store);
    final dialer = DesktopServerDialer(
      store: store,
      timeout: const Duration(seconds: 3),
      relayFactory: relayTransport,
    );
    addTearDown(dialer.close);
    return (dialer, pairing);
  }

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a link on a relay says which relay', () async {
    await start();
    final (dialer, pairing) = await saved();
    final routes = <Uri?>[];
    final link = await dialer.dial(pairing, onRoute: routes.add);
    addTearDown(() => link.close());
    expect(routes, [firstUri]);
  });

  test('a link at an address says it is on no relay', () async {
    final host = await start();
    final (dialer, pairing) = await saved(
      direct: '127.0.0.1:${host.lanPortBound}',
    );
    final routes = <Uri?>[];
    final link = await dialer.dial(pairing, onRoute: routes.add);
    addTearDown(() => link.close());
    expect(routes, [null]);
  });

  test('a link resumed on another relay says the new one', () async {
    await start();
    final (dialer, pairing) = await saved();
    final routes = <Uri?>[];
    final link = await dialer.dial(
      pairing,
      resumeOffered: () => true,
      onRoute: routes.add,
    );
    addTearDown(() => link.close());
    expect(routes, [firstUri]);
    await first.close();
    await until(() => routes.length >= 2);
    expect(routes.last, secondUri);
  });
}
