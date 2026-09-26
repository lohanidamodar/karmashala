/// Make-before-break: the relay→LAN upgrade is a second link, not a drop.
///
/// The old upgrade was a hang-up wearing an optimisation's name — `_declareDead`,
/// a teardown, a fresh generation, transcripts marked stale and a walk to find
/// what went missing while nobody was carrying anything. All of that is paid
/// for by the user, in rows that arrive late or twice, so this file counts
/// **rows and frames** rather than watching a clock: a promotion is correct
/// when every turn crosses exactly once and the link never once claims to be
/// down.
///
/// The beacon is the only event here. Nothing polls, and the hysteresis that
/// keeps a flapping LAN from oscillating is counted in beacons for the same
/// reason (§19): a timer would be a second opinion about a world the beacon is
/// already reporting on.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart' as stored;
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// Counts what this phone put on the wire, which is what a promotion costs.
class CountingLanTransport extends LanTransport {
  CountingLanTransport({
    required super.host,
    required super.port,
    super.connectTimeout,
    super.backoff,
  });

  int sent = 0;
  final List<List<int>> outbound = [];

  @override
  void send(List<int> frame) {
    sent++;
    outbound.add(List<int>.of(frame));
    super.send(frame);
  }
}

/// What [frames] carried, opened with the host's own key: an ack is flow
/// control, timed by a coalescing timer, so it is counted apart from requests.
Future<List<String>> frameTypes(
  List<List<int>> frames,
  PairedDevice device,
) async {
  final channel = await SealedChannel.forDevice(
    deviceKey: SecretKeyData(device.deviceKey),
    role: ChannelRole.host,
    generation: device.generation,
    replayWindow: 1 << 16,
  );
  return [
    for (final frame in frames)
      if (LinkHello.tryDecode(Uint8List.fromList(frame)) != null)
        'hello'
      else
        Envelope.fromBytes((await channel.unseal(frame)).plaintext).type,
  ];
}

/// A LAN transport that answers the hello and then swallows everything.
///
/// The socket reads `connected`, the sealed round trip really happened, and
/// nothing sent after it ever leaves the phone — a half-open path, and the one
/// shape a promotion could adopt and then be wedged on.
class DeafAfterHelloTransport extends LanTransport {
  DeafAfterHelloTransport({
    required super.host,
    required super.port,
    super.connectTimeout,
    super.backoff,
  });

  int sent = 0;

  @override
  void send(List<int> frame) {
    sent++;
    if (sent > 1) return;
    super.send(frame);
  }
}

/// The same, for the relay leg — a failed promotion has to leave it carrying.
class CountingRelayTransport extends RelayTransport {
  CountingRelayTransport({
    required super.endpoint,
    super.heartbeat,
    super.connectTimeout,
    super.backoff,
  });

  int sent = 0;

  @override
  void send(List<int> frame) {
    sent++;
    super.send(frame);
  }
}

/// A beacon that fires when the test says so, and nothing else. Its own
/// cooldown is off: what is being measured here is the gateway's hysteresis,
/// and a second timed grudge underneath it would answer first.
class ScriptedScout extends LanPathScout {
  ScriptedScout({super.dialer, super.attemptTimeout});

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

/// A TCP shim in front of the desktop's LAN listener, so a test can cut the
/// direct path without touching the desktop or the relay it is also on.
class LanCut {
  LanCut._(this._server);

  final ServerSocket _server;
  final _live = <Socket>[];

  int get port => _server.port;

  static Future<LanCut> inFrontOf(int target) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final cut = LanCut._(server);
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
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late stored.InMemoryCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];
  final relayTransports = <CountingRelayTransport>[];
  final lanTransports = <CountingLanTransport>[];
  final logs = <String>[];

  final hostId = DeviceId.parse('11111111222222223333333344444444');

  const loneTimeout = Duration(seconds: 1);
  const heartbeat = Duration(milliseconds: 300);

  setUp(() async {
    dao = MemoryPairedDeviceStore();
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(loneTimeout: loneTimeout),
    );
    relayUri = Uri.parse('ws://127.0.0.1:${relay.port}');
    store = stored.InMemoryCompanionStore();
    store.values[RemoteCompanionGateway.kPairingRelayStoreKey] = relayUri
        .toString();
    relayTransports.clear();
    lanTransports.clear();
    logs.clear();
  });

  tearDown(() async {
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    await service?.stop();
    service = null;
    await relay.close();
  });

  Future<RemoteHostService> startService() async {
    final started = service = RemoteHostService(
      devices: dao,
      hostId: hostId,
      bindings: fake.bindings,
      relay: relayUri,
      localRelayUrl: relayUri,
      hostedEnabled: false,
      lanPort: 0,
      advertise: false,
      // The sweep is driven by the test, so a poll can never be mistaken for
      // the promotion carrying something.
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

  RemoteCompanionGateway makeGateway({
    LanPathScout? scout,
    Duration requestTimeout = const Duration(seconds: 5),
    Duration linkHealGrace = const Duration(milliseconds: 800),
  }) {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Test phone',
      lan: scout,
      relayFactory: (url, rendezvous) {
        final transport = CountingRelayTransport(
          endpoint: RelayTransport.endpointFor(url, rendezvous),
          backoff: fastBackoff(),
          heartbeat: heartbeat,
        )..start();
        relayTransports.add(transport);
        return transport;
      },
      requestTimeout: requestTimeout,
      helloTimeout: const Duration(milliseconds: 600),
      linkHealGrace: linkHealGrace,
      reconnectBackoff: fastBackoff(),
      onLog: logs.add,
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

  Future<void> until(
    bool Function() check, {
    Duration timeout = const Duration(seconds: 20),
    required String reason,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!check()) {
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<RemoteCompanionGateway> pairedPhone({
    LanPathScout? scout,
    Duration requestTimeout = const Duration(seconds: 5),
    Duration linkHealGrace = const Duration(milliseconds: 800),
  }) async {
    final gateway = makeGateway(
      scout: scout,
      requestTimeout: requestTimeout,
      linkHealGrace: linkHealGrace,
    );
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
      relay: relayUri,
      relayIsLocal: true,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    expect(gateway.linkPath, CompanionLinkPath.relay);
    return gateway;
  }

  /// A beacon claiming an address the relay is NOT on — otherwise the gateway
  /// is right to refuse: a "direct" socket to the machine already serving the
  /// relay buys one hop and costs a link.
  DiscoveredHost beaconAt(int port) => DiscoveredHost(
    address: InternetAddress('192.168.99.99'),
    advert: LanAdvert(port: port, tag: 'test'),
    seenAt: DateTime.now(),
  );

  /// Every promotion says how it ended, on the gateway's own log — which is
  /// what lets this file wait for the *event* rather than for a duration.
  int outcomes() => logs.where((l) => l.startsWith('lan promotion:')).length;

  Future<void> beaconOnce(ScriptedScout scout, DiscoveredHost host) async {
    final before = outcomes();
    scout.hear(host);
    await until(
      () => outcomes() > before,
      reason:
          'every beacon that reaches the promotion is answered — a dial, '
          'or a hold-off that says how many beacons are left',
    );
  }

  List<RemoteTranscriptMessage> conversation(int count, {int from = 0}) => [
    for (var i = from; i < from + count; i++)
      RemoteTranscriptMessage(role: i.isEven ? 'user' : 'agent', text: 'm$i'),
  ];

  group('a promotion is a second link, not a drop', () {
    test(
      'every row crosses exactly once, and the link never says it is down',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final started = await startService();
        fake.transcripts['s1'] = conversation(12);
        final scout = ScriptedScout(
          attemptTimeout: const Duration(seconds: 2),
          dialer: (host, port) {
            final transport = CountingLanTransport(
              host: '127.0.0.1',
              port: started.lanPortBound!,
              connectTimeout: const Duration(seconds: 2),
              backoff: fastBackoff(),
            )..start();
            lanTransports.add(transport);
            return transport;
          },
        );
        final gateway = await pairedPhone(scout: scout);

        final rows = <List<CompanionChatMessage>>[];
        final watching = gateway.transcript('s1').listen(rows.add);
        addTearDown(watching.cancel);
        await until(
          () => rows.isNotEmpty && rows.last.length == 12,
          reason: 'the phone reads the transcript over the relay first',
        );

        // Three turns while the relay is still the link.
        fake.transcripts['s1']!.addAll(conversation(3, from: 12));
        await started.pollTranscriptsNow();
        await until(
          () => rows.last.length == 15,
          reason: 'the relay carries what it is there to carry',
        );

        final states = <CompanionLinkState>[];
        final watch = gateway.linkStates.listen(states.add);
        addTearDown(watch.cancel);
        final upSince = gateway.linkSince;

        await beaconOnce(scout, beaconAt(started.lanPortBound!));
        await until(
          () => gateway.linkPath == CompanionLinkPath.lan,
          reason: 'the beacon named a desktop on this network and it answered',
        );

        expect(
          states.where((s) => s != CompanionLinkState.connected),
          isEmpty,
          reason:
              'the whole point: nothing about the switch may be visible as '
              'an outage, because there was not one',
        );
        expect(
          gateway.linkSince,
          upSince,
          reason:
              'the link is the same link — its age keeps running, and a '
              'stamp that moved would be claiming a break that did not happen',
        );

        // Four more turns, now over the LAN.
        fake.transcripts['s1']!.addAll(conversation(4, from: 15));
        await started.pollTranscriptsNow();
        await until(
          () => rows.last.length == 19,
          reason: 'the new link carries what the old one was carrying',
        );

        expect(
          [for (final message in rows.last) message.text],
          [for (var i = 0; i < 19; i++) 'm$i'],
          reason:
              'exactly once, in order, across the switch — a re-read of the '
              'tail would show the last page twice and a gap walk would show '
              'the join',
        );
        expect(
          rows.any((frame) => frame.length < 12),
          isFalse,
          reason: 'and the view never went backwards on the way',
        );

        // Hello, one subscribe, one cursor re-arm. The host builds a fresh
        // session api per generation, so both of the latter are carrying state
        // over rather than recovering from a loss.
        final carried = await frameTypes(
          lanTransports.single.outbound,
          dao.getActive().single,
        );
        expect(
          carried.where((type) => type != FrameType.streamAck.wire),
          hasLength(3),
          reason: 'what a promotion costs on the wire: $carried',
        );
      },
    );

    test(
      'a LAN dial that fails leaves the relay link carrying',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        await startService();
        final scout = ScriptedScout(
          attemptTimeout: const Duration(milliseconds: 300),
          // Nothing is listening: a firewall on the advertised LAN port, the
          // ordinary case on a freshly installed desktop.
          dialer: (host, port) => LanTransport.dial(
            host: '127.0.0.1',
            port: 1,
            connectTimeout: const Duration(milliseconds: 100),
            backoff: fastBackoff(),
          ),
        );
        final gateway = await pairedPhone(scout: scout);
        expect((await gateway.listSessions()).single.id, 's1');

        final states = <CompanionLinkState>[];
        final watch = gateway.linkStates.listen(states.add);
        addTearDown(watch.cancel);
        final sentBefore = relayTransports.last.sent;

        await beaconOnce(scout, beaconAt(41234));

        expect(scout.dials, 1, reason: 'worth trying — once');
        expect(gateway.link, CompanionLinkState.connected);
        expect(gateway.linkPath, CompanionLinkPath.relay);
        expect(
          states.where((s) => s != CompanionLinkState.connected),
          isEmpty,
          reason:
              'a dial that found nobody is not news about the link that '
              'works — it never learned anything about the relay at all',
        );
        expect(
          (await gateway.listSessions()).single.id,
          's1',
          reason:
              'and the relay still answers, which is the only proof that '
              'matters',
        );
        expect(
          relayTransports.last.sent,
          greaterThan(sentBefore),
          reason: 'frames kept flowing on it throughout, counted',
        );
      },
    );

    test(
      'a link that answers the hello and then carries nothing does not get '
      'the switch',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final started = await startService();
        final scout = ScriptedScout(
          attemptTimeout: const Duration(seconds: 2),
          dialer: (host, port) => DeafAfterHelloTransport(
            host: '127.0.0.1',
            port: started.lanPortBound!,
            connectTimeout: const Duration(seconds: 2),
            backoff: fastBackoff(),
          )..start(),
        );
        final gateway = await pairedPhone(
          scout: scout,
          // Short, so the frame that will never be answered is not what this
          // test spends its time on.
          requestTimeout: const Duration(milliseconds: 400),
          // Long, so the heal cannot answer the question before the assertion
          // does: what is being pinned here is the switch, not the recovery.
          linkHealGrace: const Duration(seconds: 5),
        );

        await beaconOnce(scout, beaconAt(started.lanPortBound!));

        expect(
          gateway.linkPath,
          CompanionLinkPath.relay,
          reason:
              'a sealed round trip proves who is there, not that the path '
              'carries — so the switch is not finished until the new link has '
              'carried a frame, and this one never did',
        );
        expect(scout.dials, 1);
      },
    );
  });

  test(
    'a failed promotion waits out beacons, doubling — never a clock',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      await startService();
      final scout = ScriptedScout(
        attemptTimeout: const Duration(milliseconds: 200),
        dialer: (host, port) => LanTransport.dial(
          host: '127.0.0.1',
          port: 1,
          connectTimeout: const Duration(milliseconds: 100),
          backoff: fastBackoff(),
        ),
      );
      final gateway = await pairedPhone(scout: scout);
      final host = beaconAt(41234);

      // 1, 2, 4: each failure asks for twice as many beacons as the last, and
      // every beacon in between is answered by counting rather than by dialling.
      // The tenth beacon is the fourth attempt, which is the whole claim.
      const dialsAfterBeacon = [1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 4];
      for (var i = 0; i < dialsAfterBeacon.length; i++) {
        await beaconOnce(scout, host);
        expect(
          scout.dials,
          dialsAfterBeacon[i],
          reason: 'beacon ${i + 1} of ${dialsAfterBeacon.length}',
        );
      }
      expect(gateway.link, CompanionLinkState.connected);
      expect(gateway.linkPath, CompanionLinkPath.relay);
      expect((await gateway.listSessions()).single.id, 's1');
    },
  );

  test(
    'a LAN link that dies after a promotion falls back through the loop '
    'that was always there',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final started = await startService();
      final cut = await LanCut.inFrontOf(started.lanPortBound!);
      addTearDown(cut.cut);
      final scout = ScriptedScout(
        attemptTimeout: const Duration(milliseconds: 600),
        dialer: (host, port) => LanTransport.dial(
          host: '127.0.0.1',
          port: cut.port,
          connectTimeout: const Duration(milliseconds: 500),
          backoff: fastBackoff(),
        ),
      );
      final gateway = await pairedPhone(scout: scout);

      await beaconOnce(scout, beaconAt(cut.port));
      await until(
        () => gateway.linkPath == CompanionLinkPath.lan,
        reason: 'the promotion lands first',
      );

      // The desktop is still there; the network between it and this phone is
      // not. Today's rules from here: the loop re-dials every saved path.
      await cut.cut();
      await until(
        () =>
            gateway.link == CompanionLinkState.connected &&
            gateway.linkPath == CompanionLinkPath.relay,
        timeout: const Duration(seconds: 30),
        reason: 'the relay takes the link back with no help from anything new',
      );
      expect((await gateway.listSessions()).single.id, 's1');
    },
  );
}
