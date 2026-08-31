/// The connect loop's two ways out, and what happens when one is lost.
///
/// Owner: "mobile pairs but unable to connect, just connecting to your
/// desktop and nothing to show yet" — and, separately, "mobile connection is
/// not stable, keeps dropping even though desktop is working and live".
///
/// The loop leaves `connecting` only when a dial returns, and leaves a live
/// link only when its death completer fires. Both could go missing: a death
/// declared while the link was still being brought up had no completer to
/// land on and was thrown away, and a beacon from a desktop the phone cannot
/// dial directly killed a working relay link on a two-minute schedule.
library;

import 'dart:async';
import 'dart:io' show InternetAddress;

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/remote_companion_gateway.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/client/companion_store.dart'
    as stored;
import 'package:chitragupta/src/features/remote/client/lan_path.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/transport/lan_beacon.dart';
import 'package:chitragupta/src/features/remote/transport/relay_transport.dart';
import 'package:chitragupta/src/features/remote/transport/remote_transport.dart';
import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// A keystore as slow as a real one on a bad day, so a test can stand inside
/// the window the gateway used to lose deaths in instead of racing it.
class SlowStore implements stored.CompanionStore {
  SlowStore(this.disk);

  final Map<String, String> disk;
  Duration writeCost = Duration.zero;

  @override
  Future<String?> read(String key) async => disk[key];

  @override
  Future<void> write(String key, String value) async {
    if (writeCost > Duration.zero) await Future<void>.delayed(writeCost);
    disk[key] = value;
  }

  @override
  Future<void> delete(String key) async => disk.remove(key);
}

/// A scout that hears one desktop's beacon on demand and can never dial it —
/// a LAN port behind a firewall, which is the ordinary case.
class DeafScout extends LanPathScout {
  DeafScout({super.dialer, super.attemptTimeout});

  final _heard = StreamController<DiscoveredHost>.broadcast();
  final _seen = <DiscoveredHost>[];
  int dials = 0;

  /// Pretend the grudge has already expired, which is what makes the beacon
  /// come back around every two minutes on a real phone.
  @override
  bool inCooldown(DiscoveredHost host) => false;

  @override
  Stream<DiscoveredHost> get sightings => _heard.stream;

  @override
  List<DiscoveredHost> get candidates => List.of(_seen);

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await _heard.close();
  }

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
  late Map<String, String> phoneDisk;
  late SlowStore store;
  final gateways = <RemoteCompanionGateway>[];
  final phoneTransports = <RelayTransport>[];

  final hostId = DeviceId.parse('11111111222222223333333344444444');

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: Duration(seconds: 30)),
    );
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    phoneDisk = {
      RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
    };
    store = SlowStore(phoneDisk);
    phoneTransports.clear();
  });

  tearDown(() async {
    store.writeCost = Duration.zero;
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    await service?.stop();
    service = null;
    await relay.close();
    db.close();
  });

  Future<RemoteHostService> startService({Uri? localRelayUrl}) async {
    final started = service = RemoteHostService(
      devices: dao,
      hostId: hostId,
      bindings: fake.bindings,
      relay: relayUri,
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

  RemoteCompanionGateway makeGateway({LanPathScout? scout}) {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceName: 'Test phone',
      lan: scout,
      relayFactory: (relay, rendezvous) {
        final transport = RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 500),
        )..start();
        phoneTransports.add(transport);
        return transport;
      },
      requestTimeout: const Duration(milliseconds: 500),
      helloTimeout: const Duration(milliseconds: 150),
      reconnectBackoff: fastBackoff(),
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
    final session = await service!.beginPairing(capabilities: CapabilitySet.all);
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    return gateway;
  }

  test('a link that dies while it is still coming up is re-dialled, not '
      'parked on for ever', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    await startService();
    final gateway = await pairedPhone();

    // From here every keystore write is slow, which is what widens the window
    // between "the dial came back" and "the loop is watching for a death"
    // from microseconds to something a test can stand inside. On a phone that
    // window is the platform channel's own latency.
    store.writeCost = const Duration(milliseconds: 400);

    var arming = false;
    var killed = false;
    final watch = gateway.linkStates.listen((state) {
      if (state != CompanionLinkState.connected || !arming || killed) return;
      killed = true;
      // Inside the window: the desktop goes away and the socket bounces, so
      // the phone's re-proof finds nobody and declares the link dead — with
      // nothing yet in existence for that death to land on.
      unawaited(() async {
        await service?.stop();
        service = null;
        await phoneTransports.last.abort();
      }());
    });
    addTearDown(watch.cancel);

    // Force a fresh pass through that window.
    await service!.stop();
    service = null;
    await awaitLink(gateway, CompanionLinkState.disconnected);
    // A relay set the phone has not seen before, so the host's greeting
    // really does have to be written down — which is the awaited keystore
    // work the loop used to lose deaths behind.
    arming = true;
    await startService(localRelayUrl: Uri.parse('ws://127.0.0.1:1'));
    while (!killed) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    store.writeCost = Duration.zero;

    // The desktop comes back. Nobody touches the phone: it must re-dial on
    // its own, exactly as it does after any other outage.
    await startService(localRelayUrl: Uri.parse('ws://127.0.0.1:2'));
    await awaitLink(
      gateway,
      CompanionLinkState.connected,
      timeout: const Duration(seconds: 20),
    );
    expect((await gateway.listSessions()).single.id, 's1');
  });

  test('a desktop the phone can hear but cannot dial does not cost it the '
      'link that works', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    await startService();
    // Every direct dial refuses at once: the advertised port is closed.
    final scout = DeafScout(
      attemptTimeout: const Duration(milliseconds: 150),
      dialer: (host, port) => RelayTransport(
        endpoint: Uri.parse('ws://127.0.0.1:1'),
        backoff: fastBackoff(),
        connectTimeout: const Duration(milliseconds: 50),
      )..start(),
    );
    final gateway = await pairedPhone(scout: scout);
    expect(gateway.linkPath, CompanionLinkPath.relay);

    final beacon = DiscoveredHost(
      address: InternetAddress('127.0.0.1'),
      advert: const LanAdvert(port: 41234, tag: 'test'),
      seenAt: DateTime.now(),
    );

    // The beacon repeats every two seconds, and the scout's grudge lasts two
    // minutes — so on a real phone this sequence plays out every two minutes,
    // for as long as the desktop is up and advertising.
    final states = <CompanionLinkState>[];
    final watch = gateway.linkStates.listen(states.add);
    addTearDown(watch.cancel);
    for (var i = 0; i < 6; i++) {
      scout.hear(beacon);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await watch.cancel();

    expect(
      scout.dials,
      greaterThan(0),
      reason: 'the direct path is worth trying — once',
    );
    expect(
      states.where((s) => s == CompanionLinkState.connecting),
      hasLength(1),
      reason: 'one upgrade attempt for six sightings: a path already proved '
          'unusable must not keep costing the link that works',
    );
    expect(gateway.link, CompanionLinkState.connected);
    expect((await gateway.listSessions()).single.id, 's1');
  });
}
