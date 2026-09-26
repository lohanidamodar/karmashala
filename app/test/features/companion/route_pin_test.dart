/// Manual route choice, where it has to hold: the real [RemoteCompanionGateway]
/// against a real [RemoteHostService] over two in-process relays and a real LAN
/// listener.
///
/// A pin means "only". Every test here pins a route, takes it away, and checks
/// that the phone did **not** go looking elsewhere — that is the promise a
/// person relies on when they pin the relay on their own box — and then that
/// Auto brings the link back.
library;

import 'dart:async';
import 'dart:io';

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart' as stored;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// A beacon that fires only when the test says so, and counts its dials.
class _ScriptedScout extends LanPathScout {
  _ScriptedScout({super.dialer, super.attemptTimeout});

  final _heard = StreamController<DiscoveredHost>.broadcast();
  final _seen = <DiscoveredHost>[];
  int dials = 0;

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

/// A TCP shim in front of the desktop's LAN listener, so the LAN path can be
/// cut without touching the desktop or its relays.
class _LanCut {
  _LanCut._(this._server);

  final ServerSocket _server;
  final _live = <Socket>[];

  int get port => _server.port;

  static Future<_LanCut> inFrontOf(int target) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final cut = _LanCut._(server);
    server.listen((down) async {
      cut._live.add(down);
      final Socket up;
      try {
        up = await Socket.connect(InternetAddress.loopbackIPv4, target);
      } on Object {
        down.destroy();
        return;
      }
      cut._live.add(up);
      down.listen(up.add, onDone: up.destroy, onError: (Object _) {});
      up.listen(down.add, onDone: down.destroy, onError: (Object _) {});
    });
    return cut;
  }

  Future<void> cut() async {
    await _server.close();
    for (final socket in _live) {
      socket.destroy();
    }
    _live.clear();
  }
}

void main() {
  late MemoryPairedDeviceStore dao;
  late FakeRemoteBindings fake;
  late RelayServer hosted;
  late RelayServer local;
  late Uri hostedUri;
  late Uri localUri;
  var localClosed = false;
  RemoteHostService? service;
  late stored.InMemoryCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];

  /// Every relay this phone dialled, by URL, in order.
  final relayDials = <Uri>[];

  setUp(() async {
    dao = MemoryPairedDeviceStore();
    fake = FakeRemoteBindings()..addSession('s1');
    hosted = await RelayServer.bind(address: '127.0.0.1', port: 0);
    local = await RelayServer.bind(address: '127.0.0.1', port: 0);
    localClosed = false;
    hostedUri = Uri.parse('ws://127.0.0.1:${hosted.port}');
    localUri = Uri.parse('ws://127.0.0.1:${local.port}');
    store = stored.InMemoryCompanionStore();
    // Never the internet: the phone's configured relay is this suite's hosted.
    store.values[RemoteCompanionGateway.kPairingRelayStoreKey] = hostedUri
        .toString();
    relayDials.clear();
  });

  tearDown(() async {
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    await service?.stop();
    service = null;
    await hosted.close();
    if (!localClosed) await local.close();
  });

  Future<RemoteHostService> startService() async {
    final started = service = RemoteHostService(
      devices: dao,
      hostId: DeviceId.parse('11111111222222223333333344444444'),
      bindings: fake.bindings,
      relay: hostedUri,
      localRelayUrl: localUri,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: (url, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(url, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 300),
      )..start(),
    );
    await started.start();
    return started;
  }

  RemoteCompanionGateway makeGateway({LanPathScout? scout}) {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Test phone',
      lan: scout,
      relayFactory: (url, rendezvous) {
        relayDials.add(url);
        return RelayTransport(
          endpoint: RelayTransport.endpointFor(url, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 300),
        )..start();
      },
      requestTimeout: const Duration(seconds: 3),
      helloTimeout: const Duration(seconds: 1),
      linkHealGrace: const Duration(milliseconds: 800),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  Future<void> until(
    bool Function() check, {
    Duration timeout = const Duration(seconds: 30),
    required String reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!check()) {
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<RemoteCompanionGateway> pairedPhone({LanPathScout? scout}) async {
    final gateway = makeGateway(scout: scout);
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await until(
      () => gateway.link == CompanionLinkState.connected,
      reason: 'the phone pairs and connects',
    );
    await until(
      () => gateway.connections.single.relays.length >= 2,
      reason: 'the desktop announces both of its relays',
    );
    return gateway;
  }

  String hostId(RemoteCompanionGateway gateway) =>
      gateway.connections.single.hostId;

  Future<stored.CompanionPairing> saved() async =>
      (await stored.CompanionConnections.load(store)).active!;

  bool pinnedTrouble(RemoteCompanionGateway gateway) =>
      gateway.linkTrouble?.contains('pinned') ?? false;

  test(
    'pinned to one relay, the phone uses only it, stays off the others when '
    'it stops answering, and Auto brings it back',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      final gateway = await pairedPhone();
      expect(
        gateway.connections.single.relays,
        containsAll(<Uri>[hostedUri, localUri]),
        reason: 'the picker offers what the desktop announced',
      );

      await gateway.setRoutePin(
        hostId(gateway),
        CompanionRoutePin.relay(localUri),
      );
      await until(
        () =>
            gateway.link == CompanionLinkState.connected &&
            gateway.activeRelay == localUri,
        reason: 'a pin takes effect at once, on the route it names',
      );
      expect(gateway.connections.single.pin, CompanionRoutePin.relay(localUri));
      expect((await saved()).pin, CompanionRoutePin.relay(localUri));

      // Take the pinned relay away.
      final dialsBefore = relayDials.length;
      await local.close();
      localClosed = true;
      await until(
        () => gateway.link != CompanionLinkState.connected,
        reason: 'the phone notices the pinned relay went',
      );
      await until(
        () => pinnedTrouble(gateway),
        reason: 'the phone says the pinned route is not answering',
      );
      // Long enough for several heal-and-redial rounds at the test's backoff.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(gateway.link, isNot(CompanionLinkState.connected));
      expect(
        relayDials.skip(dialsBefore).where((url) => url == hostedUri),
        isEmpty,
        reason: 'a pin is "only": the hosted relay is never tried behind it',
      );

      await gateway.setRoutePin(hostId(gateway), CompanionRoutePin.auto);
      await until(
        () =>
            gateway.link == CompanionLinkState.connected &&
            gateway.activeRelay == hostedUri,
        reason: 'Auto finds the route that still answers',
      );
      expect(gateway.linkTrouble, isNull);
      expect((await saved()).pin, CompanionRoutePin.auto);
    },
  );

  test(
    'a pin survives a restart of the phone',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await startService();
      final first = await pairedPhone();
      await first.setRoutePin(hostId(first), CompanionRoutePin.relay(localUri));
      await until(
        () =>
            first.link == CompanionLinkState.connected &&
            first.activeRelay == localUri,
        reason: 'pinned to the local relay',
      );
      await first.close();
      gateways.remove(first);

      relayDials.clear();
      final second = makeGateway();
      await until(
        () => second.link == CompanionLinkState.connected,
        reason: 'the restarted phone reconnects',
      );
      expect(second.activeRelay, localUri);
      expect(relayDials.toSet(), {
        localUri,
      }, reason: 'and dialled nothing else');
      expect(second.connections.single.pin, CompanionRoutePin.relay(localUri));
    },
  );

  test(
    'pinned to the LAN, the relays are never dialled, even when the LAN '
    'goes',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final started = await startService();
      final shim = await _LanCut.inFrontOf(started.lanPortBound!);
      final scout = _ScriptedScout(
        attemptTimeout: const Duration(seconds: 1),
        dialer: (host, port) => LanTransport(
          host: '127.0.0.1',
          port: shim.port,
          connectTimeout: const Duration(seconds: 1),
          backoff: fastBackoff(),
        )..start(),
      );
      final gateway = await pairedPhone(scout: scout);
      expect(gateway.linkPath, CompanionLinkPath.relay);

      final relaysBefore = relayDials.length;
      await gateway.setRoutePin(hostId(gateway), CompanionRoutePin.lan);
      // Nothing on the LAN has been heard yet (a loopback relay announces no LAN
      // address), so the pin says so rather than taking the relay it was on.
      await until(
        () => pinnedTrouble(gateway),
        reason: 'pinned to a LAN it has not heard, the phone says so',
      );
      // Then the desktop's beacon arrives, as it does once the phone is home.
      scout.hear(
        DiscoveredHost(
          address: InternetAddress('192.168.99.99'),
          advert: LanAdvert(port: shim.port, tag: 'test'),
          seenAt: DateTime.now(),
        ),
      );
      await until(
        () =>
            gateway.link == CompanionLinkState.connected &&
            gateway.linkPath == CompanionLinkPath.lan,
        reason: 'the LAN pin reaches the desktop once it is heard',
      );
      expect(gateway.linkTrouble, isNull);

      await shim.cut();
      await until(
        () => gateway.link != CompanionLinkState.connected,
        reason: 'the phone notices the LAN went',
      );
      await until(
        () => pinnedTrouble(gateway),
        reason: 'the phone says the pinned route is not answering',
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(gateway.link, isNot(CompanionLinkState.connected));
      expect(
        relayDials.length,
        relaysBefore,
        reason: 'pinned to the LAN, no relay was dialled at all',
      );

      await gateway.setRoutePin(hostId(gateway), CompanionRoutePin.auto);
      await until(
        () => gateway.link == CompanionLinkState.connected,
        reason: 'Auto falls back to a relay',
      );
      expect(gateway.linkPath, CompanionLinkPath.relay);
    },
  );

  test(
    'pinned to a relay, a beacon from the desktop is not followed',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final started = await startService();
      final scout = _ScriptedScout(
        attemptTimeout: const Duration(seconds: 1),
        dialer: (host, port) => LanTransport(
          host: '127.0.0.1',
          port: started.lanPortBound!,
          connectTimeout: const Duration(seconds: 1),
          backoff: fastBackoff(),
        )..start(),
      );
      final gateway = await pairedPhone(scout: scout);
      await gateway.setRoutePin(
        hostId(gateway),
        CompanionRoutePin.relay(hostedUri),
      );
      await until(
        () =>
            gateway.link == CompanionLinkState.connected &&
            gateway.activeRelay == hostedUri,
        reason: 'pinned to the hosted relay',
      );
      final dials = scout.dials;

      scout.hear(
        DiscoveredHost(
          address: InternetAddress('192.168.99.99'),
          advert: LanAdvert(port: started.lanPortBound!, tag: 'test'),
          seenAt: DateTime.now(),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 2));

      expect(scout.dials, dials, reason: 'no LAN dial behind a relay pin');
      expect(gateway.linkPath, CompanionLinkPath.relay);
      expect(gateway.activeRelay, hostedUri);
    },
  );
}
