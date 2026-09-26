/// Relay-free pairing, end to end and in process: the real gateway races the
/// LAN (loopback multicast beacon + direct socket) against the relay for BOTH
/// the QR and the typed-code paths. A dead relay must not sink pairing when
/// the desktop is on the same network; only when both legs fail does one
/// combined sentence say which failed how.
library;

import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart' as stored;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/pairing.dart' hide PairingException;
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// A beacon group of this suite's own, so a real host on the LAN cannot leak
/// into it (the lan_beacon_test convention). The PORT is per test, from
/// [freeBeaconPort] — see there for why sharing one across a file is a flake.
final _lanGroup = InternetAddress('239.255.42.203');

void main() {
  /// This test's beacon port, and one nothing ever advertises on, for the
  /// test whose whole point is that the LAN leg finds nobody.
  late int lanPort;
  late int silentLanPort;
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  RelayServer? relay;
  late Uri relayUri;
  RemoteHostService? service;
  late stored.InMemoryCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];

  /// A URL nothing listens on — bind a port, close it, dial the corpse.
  Future<Uri> deadRelay() async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final port = socket.port;
    await socket.close();
    return Uri.parse('ws://127.0.0.1:$port');
  }

  setUp(() async {
    lanPort = await freeBeaconPort();
    silentLanPort = await freeBeaconPort();
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay!.port}');
    store = stored.InMemoryCompanionStore();
    // Loop 83's last-resort relay is the phone's configured one, which
    // defaults to the public PopupBits relay — point it here instead. The
    // tests that care set their own over the top.
    store.values[RemoteCompanionGateway.kPairingRelayStoreKey] = relayUri
        .toString();
  });

  tearDown(() async {
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    await service?.stop();
    service = null;
    await relay?.close();
    relay = null;
    db.close();
  });

  Future<RemoteHostService> startService({Uri? relayOverride}) async {
    final started = service = RemoteHostService(
      devices: dao,
      hostId: DeviceId.parse('11111111222222223333333344444444'),
      bindings: fake.bindings,
      relay: relayOverride ?? relayUri,
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

  RemoteCompanionGateway makeGateway({LanPathScout? lan}) {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Race phone',
      lan: lan,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
      requestTimeout: const Duration(seconds: 2),
      helloTimeout: const Duration(seconds: 2),
      pairingTimeout: const Duration(seconds: 4),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  /// [beaconPort] defaults to this test's own; the test that must hear
  /// *nothing* passes [silentLanPort], so "no desktop was found" is true by
  /// construction rather than by timing.
  LanPathScout makeScout({int? beaconPort}) => LanPathScout(
    group: _lanGroup,
    beaconPort: beaconPort ?? lanPort,
    attemptTimeout: const Duration(milliseconds: 800),
    retryCooldown: const Duration(seconds: 30),
    // The suite's listeners sit on loopback; dial there (the harness rule).
    dialer: (host, port) => LanTransport.dial(
      host: '127.0.0.1',
      port: port,
      connectTimeout: const Duration(milliseconds: 800),
      backoff: fastBackoff(),
    ),
  );

  Future<LanBeacon> advertiseHost() async {
    final beacon = await LanBeacon.advertise(
      port: service!.lanPortBound!,
      tag: 'racehost00000001',
      interval: const Duration(milliseconds: 100),
      group: _lanGroup,
      beaconPort: lanPort,
      // Loopback, so the suite never advertises onto the real network — and
      // so it still works on macOS 15+, where multicast off-machine is denied
      // until a human grants Local Network access. See lan_beacon_test.dart.
      bindAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(beacon.stop);
    return beacon;
  }

  /// A scout that has already joined the group and heard this host.
  ///
  /// The gateway starts its scout lazily, INSIDE `pairWithCode`/`pairWithQr`,
  /// and the LAN leg is bounded by the same `pairingTimeout` as the relay leg.
  /// Everything before the first sighting — the multicast join, the wait for
  /// the next beacon tick — was therefore charged to that budget, and what was
  /// left had to cover a dial plus a sealed round-trip. Joining first and
  /// proving a beacon arrived puts a candidate in `scout.candidates` before
  /// the clock starts, so the LAN leg dials on its very first pass instead of
  /// spending the budget discovering it has nothing to dial yet. Running out
  /// of that budget is `PairingException: Could not find the machine` on a
  /// run whose desktop was right there.
  Future<LanPathScout> listeningScout() async {
    final scout = makeScout();
    await scout.start();
    await scout.sightings.first.timeout(
      const Duration(seconds: 30),
      onTimeout: () => fail('no beacon arrived on this suite group'),
    );
    return scout;
  }

  test(
    'a typed code pairs over the LAN while the relay is dead',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // The desktop believes in a relay that is not there — TODAY's situation.
      final dead = await deadRelay();
      await startService(relayOverride: dead);
      await advertiseHost();
      final gateway = makeGateway(lan: await listeningScout());
      // The phone's configured relay is dead too: only the LAN can carry this.
      await gateway.setPairingRelay(dead);

      final stages = <CompanionPairingStage>[];
      final sub = gateway.pairingProgress.listen((p) => stages.add(p.stage));
      final session = await service!.beginPairing(
        capabilities: CapabilitySet.all,
      );
      final code = PairingCode.encode(session.payload.typedSecret!);

      final paired = await gateway.pairWithCode(code);
      final device = await session.done;
      await sub.cancel();

      expect(paired.hostName, 'TestHost');
      expect(
        paired.hostId,
        service!.hostId,
        reason: 'the host id travelled in the sealed confirm, not the code',
      );
      expect(paired.capabilities.has(Capability.approve), isTrue);
      expect(dao.getActive().single.id, device.id);
      expect(stages.first, CompanionPairingStage.codeAccepted);
      expect(stages, contains(CompanionPairingStage.searching));
      expect(stages, contains(CompanionPairingStage.proving));
      expect(stages.last, CompanionPairingStage.paired);

      // The link then comes up — over the LAN, since the relay is a corpse.
      await gateway.linkStates
          .firstWhere((s) => s == CompanionLinkState.connected)
          .timeout(const Duration(seconds: 60));
      expect(gateway.linkPath, CompanionLinkPath.lan);
      expect((await gateway.listSessions()).single.id, 's1');
    },
  );

  test(
    'a scanned QR pairs over the LAN while its relay is dead',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final dead = await deadRelay();
      await startService(relayOverride: dead);
      await advertiseHost();
      final gateway = makeGateway(lan: await listeningScout());

      final session = await service!.beginPairing(
        capabilities: CapabilitySet.all,
      );
      final paired = await gateway.pairWithQr(session.payload.encode());
      await session.done;

      expect(paired.hostName, 'TestHost');
      expect(dao.getActive(), hasLength(1));
    },
  );

  test('a typed code pairs over the relay when no desktop beacons', () async {
    await startService();
    final gateway = makeGateway();
    await gateway.setPairingRelay(relayUri);

    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
    );
    final code = PairingCode.encode(session.payload.typedSecret!);

    final paired = await gateway.pairWithCode(code);
    await session.done;

    expect(paired.hostName, 'TestHost');
    expect(
      (await stored.CompanionPairing.load(store))!.relay,
      relayUri,
      reason: "the record carries the phone's own configured relay",
    );
  });

  test('when both legs fail, one sentence says which failed how', () async {
    final gateway = makeGateway(lan: makeScout(beaconPort: silentLanPort));
    await gateway.setPairingRelay(await deadRelay());
    final code = PairingCode.encode(List<int>.generate(20, (i) => i + 40));

    final failures = <CompanionPairingProgress>[];
    final sub = gateway.pairingProgress.listen(failures.add);
    await expectLater(
      gateway.pairWithCode(code),
      throwsA(
        isA<PairingException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('no relay was reachable'),
            contains('no machine was found on this network'),
          ),
        ),
      ),
    );
    await sub.cancel();
    expect(failures.last.stage, CompanionPairingStage.failed);
    expect(gateway.pairing, isNull);
  });
}
