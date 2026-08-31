/// Relay-free pairing, end to end and in process: the real gateway races the
/// LAN (loopback multicast beacon + direct socket) against the relay for BOTH
/// the QR and the typed-code paths. A dead relay must not sink pairing when
/// the desktop is on the same network; only when both legs fail does one
/// combined sentence say which failed how.
library;

import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/remote_companion_gateway.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/client/companion_store.dart'
    as stored;
import 'package:chitragupta/src/features/remote/client/lan_path.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_code.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/transport/lan_beacon.dart';
import 'package:chitragupta/src/features/remote/transport/lan_transport.dart';
import 'package:chitragupta/src/features/remote/transport/relay_transport.dart';
import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// A beacon group and port of this suite's own, so a real host on the LAN
/// cannot leak into it (the lan_beacon_test convention).
final _lanGroup = InternetAddress('239.255.42.203');
const _lanPort = 47699;

/// A port nothing in this file ever advertises on, for the test whose whole
/// point is that the LAN leg finds nobody.
const _silentLanPort = 47700;

void main() {
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
      deviceName: 'Race phone',
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

  /// [beaconPort] exists for the one test that must hear *nothing*: beacons
  /// from earlier tests in this file are stopped at teardown, but a multicast
  /// packet already in flight does not know that, and under a loaded machine
  /// one arrives late enough to be heard by the next test's scout. A port of
  /// its own makes "no desktop was found" true by construction rather than by
  /// timing.
  LanPathScout makeScout({int beaconPort = _lanPort}) => LanPathScout(
    group: _lanGroup,
    beaconPort: beaconPort,
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
      beaconPort: _lanPort,
    );
    addTearDown(beacon.stop);
    return beacon;
  }

  test('a typed code pairs over the LAN while the relay is dead', () async {
    // The desktop believes in a relay that is not there — TODAY's situation.
    final dead = await deadRelay();
    await startService(relayOverride: dead);
    await advertiseHost();
    final gateway = makeGateway(lan: makeScout());
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
  });

  test('a scanned QR pairs over the LAN while its relay is dead', () async {
    final dead = await deadRelay();
    await startService(relayOverride: dead);
    await advertiseHost();
    final gateway = makeGateway(lan: makeScout());

    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
    );
    final paired = await gateway.pairWithQr(session.payload.encode());
    await session.done;

    expect(paired.hostName, 'TestHost');
    expect(dao.getActive(), hasLength(1));
  });

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
    final gateway = makeGateway(lan: makeScout(beaconPort: _silentLanPort));
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
            contains('no desktop was found on this network'),
          ),
        ),
      ),
    );
    await sub.cancel();
    expect(failures.last.stage, CompanionPairingStage.failed);
    expect(gateway.pairing, isNull);
  });
}
