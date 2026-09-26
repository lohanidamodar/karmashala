/// Pairing with a session host from its QR: the real gateway against a fake
/// box on loopback. One route per invite, stored on the record, and a dial that
/// stays on that route — straight to the address, or through the relay the
/// invite names, never across both.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:karmashala_remote/client.dart' as stored;
import 'package:karmashala_remote/client.dart'
    show InMemoryCompanionStore, LanPathScout;
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala_remote/pairing.dart' hide PairingException;
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import '../remote/transport_harness.dart';

final _hostId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _inviteRelay = Uri.parse('wss://hosted.example');

/// A box: one listener, and a pairing window that reads whatever link arrives.
class _FakeBox {
  late LanTransportServer server;
  HostPairingSession? session;
  StreamSubscription<LanLink>? _links;
  final paired = <PairedDevice>[];

  Future<void> start() async {
    server = await LanTransportServer.bind(address: '127.0.0.1', port: 0);
    _links = server.connections.listen((link) {
      final refuse = _refuse;
      if (refuse == null) {
        session?.attach(link);
        return;
      }
      link.frames.listen((frame) async {
        final hello = LinkHello.tryDecode(frame);
        if (hello != null) await refuse(hello.rendezvous.value);
        await link.close();
      });
    });
  }

  Future<void> Function(String rendezvous)? _refuse;

  Future<String> openWindow() async {
    final payload = await PairingPayload.generateWithCode(
      relay: Uri.parse('https://invalid.local'),
      hostId: _hostId,
      capabilities: CapabilitySet.all,
    );
    session = HostPairingSession(
      payload: payload,
      hostName: 'do-box',
      persist: (device) async => paired.add(device),
    );
    return PairingCode.encode(payload.typedSecret!);
  }

  /// Stops pairing and answers every session hello by hanging up, telling
  /// [onHello] which rendezvous was asked for.
  Future<void> refuseSessions(
    Future<void> Function(String rendezvous) onHello,
  ) async {
    await session?.close();
    session = null;
    _refuse = onHello;
  }

  Future<void> stop() async {
    await session?.close();
    await _links?.cancel();
    await server.close();
  }
}

/// A scout that records being used. It is never supposed to be.
class _SpyScout extends LanPathScout {
  int touched = 0;

  @override
  Future<void> start() async => touched++;

  @override
  List<DiscoveredHost> get candidates {
    touched++;
    return const [];
  }
}

void main() {
  late _FakeBox box;
  late InMemoryCompanionStore store;
  late _SpyScout scout;
  final directDials = <String>[];
  final relayDials = <Uri>[];
  final now = DateTime.utc(2026, 9, 17, 12);
  RemoteCompanionGateway? gateway;

  RemoteTransport toBox() => LanTransport(
    host: '127.0.0.1',
    port: box.server.port,
    backoff: fastBackoff(),
  )..start();

  RemoteCompanionGateway makeGateway({bool boxAnswersDirect = true}) {
    return gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Invite phone',
      lan: scout,
      now: () => now,
      directDialer: (host, port) {
        directDials.add('$host:$port');
        return toBox();
      },
      relayFactory: (relay, rendezvous) {
        relayDials.add(relay);
        return toBox();
      },
      requestTimeout: const Duration(seconds: 2),
      helloTimeout: const Duration(milliseconds: 300),
      pairingTimeout: const Duration(seconds: 4),
      reconnectBackoff: fastBackoff(),
      localReconnectBackoff: fastBackoff(),
    );
  }

  String invite(
    String code, {
    HostRoute route = HostRoute.direct,
    DateTime? expiresAt,
  }) => HostPairingInvite(
    endpoint: 'box.example.com:47820',
    code: code,
    hostName: 'do-box',
    route: route,
    relay: route == HostRoute.relay ? _inviteRelay : null,
    expiresAt: expiresAt ?? now.add(const Duration(minutes: 5)),
  ).encode();

  setUp(() async {
    box = _FakeBox();
    await box.start();
    store = InMemoryCompanionStore();
    // The phone's own configured relay, which an invite must never be raced
    // against: anything dialled here is a leak.
    store.values[RemoteCompanionGateway.kPairingRelayStoreKey] =
        'wss://configured.example';
    scout = _SpyScout();
    directDials.clear();
    relayDials.clear();
  });

  tearDown(() async {
    await gateway?.close();
    gateway = null;
    await box.stop();
  });

  test('a direct invite pairs straight at its address, stores the route, and '
      'shows the attempt to no relay and no network search', () async {
    final code = await box.openWindow();
    final paired = await makeGateway().pairWithQr(invite(code));

    expect(paired.hostName, 'do-box');
    expect(paired.hostId, _hostId);
    expect(paired.route, HostRoute.direct);
    expect(paired.directEndpoint, 'box.example.com:47820');
    expect(box.paired, hasLength(1));
    expect(directDials.first, 'box.example.com:47820');
    expect(relayDials, isEmpty);
    expect(scout.touched, 0);

    final record = (await stored.CompanionPairing.load(store))!;
    expect(record.route, HostRoute.direct);
    expect(record.directEndpoint, 'box.example.com:47820');

    final connection = gateway!.connections.single;
    expect(connection.route, HostRoute.direct);
    expect(connection.directEndpoint, 'box.example.com:47820');
  });

  test('a relay invite pairs through the relay it names — not the phone\'s '
      'configured one — and stores no address to dial', () async {
    final code = await box.openWindow();
    final paired = await makeGateway().pairWithQr(
      invite(code, route: HostRoute.relay),
    );

    expect(paired.route, HostRoute.relay);
    expect(paired.directEndpoint, isNull);
    expect(relayDials.first, _inviteRelay);
    expect(relayDials, everyElement(_inviteRelay));
    expect(directDials, isEmpty);
    expect(scout.touched, 0);

    final record = (await stored.CompanionPairing.load(store))!;
    expect(record.route, HostRoute.relay);
    expect(record.relay, _inviteRelay);
    expect(record.directEndpoint, isNull);
    expect(record.candidates.map((c) => c.url), [_inviteRelay]);
  });

  test('the paste path reads an invite too', () async {
    final code = await box.openWindow();
    final paired = await makeGateway().pairWithCode(invite(code));
    expect(paired.route, HostRoute.direct);
  });

  group('refusals say which thing is wrong, and nothing is dialled', () {
    Future<(String, List<CompanionPairingStage>)> refused(String text) async {
      final gateway = makeGateway();
      final stages = <CompanionPairingStage>[];
      final sub = gateway.pairingProgress.listen((p) => stages.add(p.stage));
      late String message;
      try {
        await gateway.pairWithQr(text);
        fail('should have been refused');
      } on PairingException catch (error) {
        message = error.message;
      }
      await sub.cancel();
      expect(directDials, isEmpty);
      expect(relayDials, isEmpty);
      return (message, stages);
    }

    test('expired', () async {
      final code = await box.openWindow();
      final (message, stages) = await refused(invite(code, expiresAt: now));
      expect(message, contains('expired'));
      expect(message, contains('new code'));
      expect(stages, [CompanionPairingStage.failed]);
    });

    test('made by a newer build', () async {
      final code = await box.openWindow();
      final json = jsonDecode(invite(code)) as Map<String, Object?>;
      json['v'] = kHostInviteVersion + 1;
      final (message, stages) = await refused(jsonEncode(json));
      expect(message, contains('newer'));
      expect(message.toLowerCase(), contains('update'));
      expect(stages, [CompanionPairingStage.failed]);
    });

    test('malformed', () async {
      final (message, stages) = await refused('{"kind":"host","v":1}');
      expect(message, contains('not a Karmashala pairing code'));
      expect(stages, [CompanionPairingStage.failed]);
    });

    test('never with the code in the sentence', () async {
      final code = await box.openWindow();
      final (message, _) = await refused(invite(code, expiresAt: now));
      expect(message, isNot(contains(code)));
    });
  });

  test('a direct host that stops answering is not looked for anywhere else, '
      'and the phone says what to do about it', () async {
    final code = await box.openWindow();
    final gateway = makeGateway();
    await gateway.pairWithQr(invite(code));
    // The fake box never answers a session hello, which is what a machine that
    // has gone behind a firewall looks like from here.
    final trouble = await gateway.linkTroubleStates
        .where((t) => t != null)
        .cast<String>()
        .first
        .timeout(const Duration(seconds: 10));

    expect(trouble, contains('box.example.com:47820'));
    expect(trouble, contains('Hosted relay'));
    expect(gateway.link, isNot(CompanionLinkState.connected));
    expect(relayDials, isEmpty, reason: 'no silent fallback across routes');
    expect(scout.touched, 0);
    expect(directDials.length, greaterThan(1));
  });

  test(
    'a box that hangs up on a stale counter is asked at the next one',
    () async {
      // The phone bumps its counter after every link and the box serves each
      // generation once. A bump that did not reach the keystore leaves the phone
      // one behind, where the box takes the socket and drops it — and with one
      // attempt per pass that phone would be locked out of a healthy machine.
      final code = await box.openWindow();
      final gateway = makeGateway();
      await gateway.pairWithQr(invite(code));
      final device = box.paired.single;
      final key = SecretKeyData(device.deviceKey);
      final asked = <int>{};
      final third = Completer<void>();
      // From here on the box is a session host that refuses every generation.
      await box.refuseSessions((rendezvous) async {
        for (var g = device.generation; g < device.generation + 4; g++) {
          if ((await rendezvousFor(key, g)).value != rendezvous) continue;
          asked.add(g);
          if (asked.length >= 3 && !third.isCompleted) third.complete();
        }
      });

      await third.future.timeout(const Duration(seconds: 10));

      expect(asked, containsAll([device.generation, device.generation + 1]));
      expect(relayDials, isEmpty, reason: 'probing forward is not a fallback');
    },
  );

  test('a relay host is dialled only at its relays', () async {
    final code = await box.openWindow();
    final gateway = makeGateway();
    await gateway.pairWithQr(invite(code, route: HostRoute.relay));
    final before = relayDials.length;
    // Long enough for a pass of the connect loop to have dialled again.
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(relayDials.length, greaterThan(before));
    expect(relayDials.toSet(), {
      _inviteRelay,
    }, reason: 'the configured relay is not a fallback for a box');
    expect(directDials, isEmpty);
    expect(scout.touched, 0);
  });

  group('the stored record', () {
    stored.CompanionPairing record({String? direct, HostRoute? route}) =>
        stored.CompanionPairing(
          hostId: _hostId,
          deviceId: DeviceId.parse('00000000111111112222222233333333'),
          deviceKey: Uint8List.fromList(List<int>.filled(32, 7)),
          capabilities: CapabilitySet.all,
          relay: _inviteRelay,
          generation: 1,
          hostName: 'do-box',
          directEndpoint: direct,
          route: route,
        );

    test('round-trips its route under `via`', () {
      final json = record(route: HostRoute.relay).toJson();
      expect(json['via'], 'relay');
      expect(stored.CompanionPairing.fromJson(json).route, HostRoute.relay);
    });

    test('written before routes existed: an address reads as direct, a '
        'desktop reads as none', () {
      final box = record(direct: 'box.example.com:47820').toJson()
        ..remove('via');
      expect(stored.CompanionPairing.fromJson(box).route, HostRoute.direct);
      final desktop = record().toJson();
      expect(desktop.containsKey('via'), isFalse);
      expect(stored.CompanionPairing.fromJson(desktop).route, isNull);
    });

    test('keeps its route across the copies a connection makes', () {
      final relay = record(route: HostRoute.relay);
      expect(relay.withGeneration(2).route, HostRoute.relay);
      expect(relay.withRelay(_inviteRelay).route, HostRoute.relay);
    });
  });
}
