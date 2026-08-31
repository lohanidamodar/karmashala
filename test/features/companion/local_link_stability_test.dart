/// Owner: "main thing is even with local relay connection is not stable? once
/// paired they should have a stable connection as long as local server is up."
///
/// That is the requirement, so this file is written as one: the link is held
/// over a compressed clock — many multiples of every timer that could fire —
/// and it must never leave `connected`. The relay's lone-peer timeout, the
/// WebSocket heartbeat, the LAN beacon's two-second repeat and an app
/// background/resume cycle all run underneath it. A stability claim with no
/// clock behind it is not a claim.
library;

import 'dart:async';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import 'package:chitragupta/src/app/companion/companion_lifecycle.dart';
import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/remote_companion_gateway.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/client/companion_store.dart'
    as stored;
import 'package:chitragupta/src/features/remote/client/lan_path.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/pairing/pairing_wire.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/transport/lan_beacon.dart';
import 'package:chitragupta/src/features/remote/transport/relay_transport.dart';
import 'package:chitragupta/src/features/remote/transport/remote_transport.dart';
import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// Counts the link helloes the phone sends, which is how a test can see the
/// difference between trusting a socket and asking the desktop to answer.
class CountingRelayTransport extends RelayTransport {
  CountingRelayTransport({
    required super.endpoint,
    super.heartbeat,
    super.connectTimeout,
    super.backoff,
  });

  int helloes = 0;

  @override
  void send(List<int> frame) {
    if (LinkHello.tryDecode(Uint8List.fromList(frame)) != null) helloes++;
    super.send(frame);
  }
}

/// A scout that beacons on demand and can never dial what it hears — the
/// ordinary shape of a desktop behind a firewall on its own LAN port.
class ScriptedScout extends LanPathScout {
  ScriptedScout({super.dialer, super.attemptTimeout});

  final _heard = StreamController<DiscoveredHost>.broadcast();
  final _seen = <DiscoveredHost>[];
  int dials = 0;

  /// The grudge is what makes the beacon come back around every two minutes
  /// on a real phone; here it has always already expired.
  @override
  bool inCooldown(DiscoveredHost host) => false;

  @override
  Stream<DiscoveredHost> get sightings => _heard.stream;

  @override
  List<DiscoveredHost> get candidates => List.of(_seen);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async => _heard.close();

  @override
  RemoteTransport dial(DiscoveredHost host) {
    dials++;
    return super.dial(host);
  }

  void hear(DiscoveredHost host) {
    if (!_seen.contains(host)) _seen.add(host);
    _heard.add(host);
  }
}

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late stored.InMemoryCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];
  final phoneTransports = <CountingRelayTransport>[];

  final hostId = DeviceId.parse('11111111222222223333333344444444');

  /// The compressed clock. Every one of these is minutes in production; the
  /// point of shrinking them is that a few seconds of test covers many
  /// multiples of each.
  const loneTimeout = Duration(seconds: 1);
  const heartbeat = Duration(milliseconds: 300);
  const beaconInterval = Duration(milliseconds: 200);

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: loneTimeout),
    );
    relayUri = Uri.parse('ws://127.0.0.1:${relay.port}');
    store = stored.InMemoryCompanionStore();
    store.values[RemoteCompanionGateway.kPairingRelayStoreKey] =
        relayUri.toString();
    phoneTransports.clear();
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
      hostId: hostId,
      bindings: fake.bindings,
      // The embedded local relay is the one being served here.
      relay: relayUri,
      localRelayUrl: relayUri,
      hostedEnabled: false,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: (url, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(url, rendezvous),
        backoff: fastBackoff(),
        heartbeat: heartbeat,
      )..start(),
    );
    await started.start();
    return started;
  }

  RemoteCompanionGateway makeGateway({LanPathScout? scout, Backoff? backoff}) {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceName: 'Test phone',
      lan: scout,
      relayFactory: (url, rendezvous) {
        final transport = CountingRelayTransport(
          endpoint: RelayTransport.endpointFor(url, rendezvous),
          backoff: fastBackoff(),
          heartbeat: heartbeat,
        )..start();
        phoneTransports.add(transport);
        return transport;
      },
      requestTimeout: const Duration(seconds: 2),
      helloTimeout: const Duration(milliseconds: 400),
      linkHealGrace: const Duration(milliseconds: 800),
      reconnectBackoff: backoff ?? fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  Future<void> awaitLink(
    RemoteCompanionGateway gateway,
    CompanionLinkState wanted, {
    Duration timeout = const Duration(seconds: 30),
  }) => gateway.linkStates
      .firstWhere((state) => state == wanted)
      .timeout(timeout);

  Future<RemoteCompanionGateway> pairedPhone({LanPathScout? scout}) async {
    final gateway = makeGateway(scout: scout);
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
      relay: relayUri,
      relayIsLocal: true,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    return gateway;
  }

  /// The desktop's beacon, arriving from the very address the local relay is
  /// served on — which is what a phone on the same network actually sees.
  DiscoveredHost beaconFor(Uri relay) => DiscoveredHost(
    address: InternetAddress(relay.host),
    advert: const LanAdvert(port: 41234, tag: 'test'),
    seenAt: DateTime.now(),
  );

  test('the link holds while the local relay is up, through the lone-peer '
      'timeout, the heartbeat and the beacon', timeout: const Timeout(
    Duration(minutes: 3),
  ), () async {
    await startService();
    final scout = ScriptedScout(
      attemptTimeout: const Duration(milliseconds: 100),
      // Nothing answers on the advertised LAN port: a firewall, the ordinary
      // case on a freshly installed desktop app.
      dialer: (host, port) => RelayTransport(
        endpoint: Uri.parse('ws://127.0.0.1:1'),
        backoff: fastBackoff(),
        connectTimeout: const Duration(milliseconds: 50),
      )..start(),
    );
    final gateway = await pairedPhone(scout: scout);
    expect(gateway.linkPath, CompanionLinkPath.relay);

    final states = <CompanionLinkState>[];
    final watch = gateway.linkStates.listen(states.add);
    addTearDown(watch.cancel);

    // Eight seconds of compressed clock: eight lone-peer timeouts, twenty-odd
    // heartbeats, forty beacons. In production that is the best part of an
    // afternoon.
    final beacon = beaconFor(relayUri);
    final ticker = Timer.periodic(beaconInterval, (_) => scout.hear(beacon));
    addTearDown(ticker.cancel);
    await Future<void>.delayed(const Duration(seconds: 8));
    ticker.cancel();
    await watch.cancel();

    expect(
      states.where((s) => s != CompanionLinkState.connected),
      isEmpty,
      reason: 'once paired, the link stays up for as long as the local relay '
          'is up — nothing may tear down a link that is answering',
    );
    expect(gateway.link, CompanionLinkState.connected);
    expect((await gateway.listSessions()).single.id, 's1');
  });

  test('a desktop that is NOT where the relay is still earns exactly one '
      'direct attempt', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    await startService();
    final scout = ScriptedScout(
      attemptTimeout: const Duration(milliseconds: 100),
      dialer: (host, port) => RelayTransport(
        endpoint: Uri.parse('ws://127.0.0.1:1'),
        backoff: fastBackoff(),
        connectTimeout: const Duration(milliseconds: 50),
      )..start(),
    );
    final gateway = await pairedPhone(scout: scout);

    // A relay somewhere else entirely: the direct path is then a real
    // upgrade, and worth one try.
    final elsewhere = DiscoveredHost(
      address: InternetAddress('192.168.99.99'),
      advert: const LanAdvert(port: 41234, tag: 'test'),
      seenAt: DateTime.now(),
    );
    final states = <CompanionLinkState>[];
    final watch = gateway.linkStates.listen(states.add);
    addTearDown(watch.cancel);
    for (var i = 0; i < 6; i++) {
      scout.hear(elsewhere);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await watch.cancel();

    expect(scout.dials, greaterThan(0), reason: 'worth trying — once');
    expect(
      states.where((s) => s == CompanionLinkState.connecting),
      hasLength(1),
      reason: 'a path already proved unusable must not keep costing the link',
    );
    expect(gateway.link, CompanionLinkState.connected);
  });

  test('a resume asks the desktop to answer instead of trusting the socket',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    await startService();
    final gateway = await pairedPhone();
    final transport = phoneTransports.last;
    final before = transport.helloes;

    // Android froze the app; on the way back the socket may be a corpse that
    // still reads "connected". The only honest way to know is to ask.
    final reconnector = CompanionLifecycleReconnector(gateway);
    reconnector.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(
      transport.helloes,
      greaterThan(before),
      reason: 'a resume must prove the link, not assume it',
    );
    expect(gateway.link, CompanionLinkState.connected);
    expect((await gateway.listSessions()).single.id, 's1');
  });

  test('a local link that does break comes back in a moment, not on the '
      'schedule an internet relay needs', timeout: const Timeout(
    Duration(minutes: 3),
  ), () async {
    await startService();
    // The schedule a far-away relay deserves — and must not be applied to a
    // desktop on the same table.
    final gateway = makeGateway(
      backoff: Backoff(
        initial: const Duration(seconds: 20),
        maximum: const Duration(seconds: 30),
        jitter: 0,
      ),
    );
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
      relay: relayUri,
      relayIsLocal: true,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);

    await service!.stop();
    service = null;
    await awaitLink(gateway, CompanionLinkState.disconnected);
    final downAt = DateTime.now();
    await startService();
    await awaitLink(
      gateway,
      CompanionLinkState.connected,
      timeout: const Duration(seconds: 15),
    );
    expect(
      DateTime.now().difference(downAt),
      lessThan(const Duration(seconds: 10)),
      reason: 'a relay on this machine is not an internet relay',
    );
  });

  test('a desktop too busy to answer one request keeps its link', timeout:
      const Timeout(Duration(minutes: 3)), () async {
    await startService();
    final gateway = await pairedPhone();
    final states = <CompanionLinkState>[];
    final watch = gateway.linkStates.listen(states.add);
    addTearDown(watch.cancel);

    // The desktop is there and answering helloes; it is simply slow on this
    // one call. Fifteen seconds of silence used to be read as a dead link.
    final busy = Completer<void>();
    fake.promptGate = busy;
    await expectLater(
      gateway.sendPrompt('s1', 'are you busy?'),
      throwsA(isA<GatewayException>()),
    );
    // Long enough for the proof to run and for a teardown to have shown up.
    await Future<void>.delayed(const Duration(seconds: 2));
    busy.complete();
    fake.promptGate = null;
    await watch.cancel();

    expect(
      states.where((s) => s != CompanionLinkState.connected),
      isEmpty,
      reason: 'one slow answer is not a broken link',
    );
    expect((await gateway.listSessions()).single.id, 's1');
  });

  test('a local relay that moves address takes its phone with it — no '
      're-pairing, ever', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    await startService();
    final gateway = await pairedPhone();
    final pairedAt = DateTime.now();

    // The desktop's LAN address moves under it: a DHCP renew, a Wi-Fi band
    // switch, a VPN coming up. The relay is the same server on a new address.
    final moved = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: loneTimeout),
    );
    addTearDown(moved.close);
    final movedUri = Uri.parse('ws://127.0.0.1:${moved.port}');
    await service!.updateRelays(localRelayUrl: movedUri, hostedEnabled: false);
    await relay.close();

    // Nothing is touched on the phone. It must find the desktop again on its
    // own — the rendezvous comes from the device key, never from the URL, so
    // an address is only ever a place to meet.
    await awaitLink(
      gateway,
      CompanionLinkState.connected,
      timeout: const Duration(seconds: 20),
    );
    expect(gateway.activeRelay, movedUri);
    expect((await gateway.listSessions()).single.id, 's1');
    expect(
      gateway.pairing?.hostId?.value,
      hostId.value,
      reason: 'the same pairing throughout — an address move is not a re-pair',
    );
    expect(DateTime.now().difference(pairedAt), lessThan(
      const Duration(seconds: 30),
    ));
  });
}
