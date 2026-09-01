/// The other half of the owner's bug: the phone's own account of itself.
///
/// Its desktop held the socket open and answered nothing. The gateway read
/// that as "a fact about the REQUEST, not about the link", kept saying
/// **connected**, and kept the last list it had been sent on screen. So the
/// phone showed projects and sessions, felt healthy, and could not open a
/// single one of them — and never re-dialled, because nothing had told it
/// anything was wrong.
///
/// A cached list is fine. Calling the desktop reachable while every live
/// request times out is not, and it is what turned a link that would have
/// healed itself on the next dial into one that never did.
library;

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/companion/client/companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/remote_companion_gateway.dart';
import 'package:chitragupta/src/features/companion/client/secure_companion_store.dart';
import 'package:chitragupta/src/features/remote/application/remote_host_service.dart';
import 'package:chitragupta/src/features/remote/data/paired_device_dao.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/transport/relay_transport.dart';
import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  RemoteHostService? service;
  late Map<String, String> phoneDisk;
  late SecureCompanionStore store;
  final gateways = <RemoteCompanionGateway>[];
  final hostLog = <String>[];

  final hostId = DeviceId.parse('11111111222222223333333344444444');

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()
      ..addSession('s1')
      ..addSession('s2');
    // Its own ephemeral port — never the machine's real relay port, which a
    // leaked listener would hold for every run after this one.
    hostLog.clear();
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    phoneDisk = {
      RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
    };
    store = SecureCompanionStore.withBackend(
      read: (key) async => phoneDisk[key],
      write: (key, value) async => phoneDisk[key] = value,
      delete: (key) async => phoneDisk.remove(key),
    );
  });

  tearDown(() async {
    fake.stageCost = Duration.zero;
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
      relay: relayUri,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      onLog: hostLog.add,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    await started.start();
    return started;
  }

  RemoteCompanionGateway makeGateway() {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceName: 'Test phone',
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
      requestTimeout: const Duration(milliseconds: 700),
      helloTimeout: const Duration(milliseconds: 500),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);
    return gateway;
  }

  Future<void> awaitLink(
    RemoteCompanionGateway gateway,
    CompanionLinkState wanted,
  ) => gateway.linkStates
      .firstWhere((state) => state == wanted)
      .timeout(const Duration(seconds: 60));

  Future<RemoteCompanionGateway> pairedPhone() async {
    final gateway = makeGateway();
    final session = await service!.beginPairing(capabilities: CapabilitySet.all);
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    return gateway;
  }

  /// A desktop that keeps the socket but stops answering: every `sessions.list`
  /// and `transcript.get` now costs far longer than the phone will wait.
  void goSilent() => fake.stageCost = const Duration(seconds: 30);

  /// Puts every stored copy of the pairing back one generation — the counter
  /// bump that never reached the keystore.
  void rewindStoredGeneration() {
    for (final key in phoneDisk.keys.toList()) {
      final raw = phoneDisk[key]!;
      if (!raw.contains('"generation"')) continue;
      phoneDisk[key] = raw.replaceAllMapped(
        RegExp(r'"generation":(\d+)'),
        (m) => '"generation":${int.parse(m.group(1)!) - 1}',
      );
    }
  }

  Future<void> eventually(
    Future<bool> Function() check, {
    Duration timeout = const Duration(seconds: 40),
    String reason = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await check()) return;
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('a phone left with only a cached list does not call itself connected',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    await startService();
    final gateway = await pairedPhone();
    expect((await gateway.listSessions()).map((s) => s.id), ['s1', 's2']);

    goSilent();

    // Two in a row, with nothing answered in between. One is a busy desktop —
    // everything for one device is serialised on a single chain, so a slow
    // binding call holds up whatever is behind it — and that must not cost the
    // link. Two is a link carrying frames one way and bringing nothing back.
    await expectLater(
      gateway.listSessions(),
      throwsA(isA<GatewayException>()),
    );
    await expectLater(
      gateway.listSessions(),
      throwsA(isA<GatewayException>()),
    );

    expect(
      gateway.link,
      isNot(CompanionLinkState.connected),
      reason: 'every live request timed out; "connected" is not a true thing '
          'to say about that link',
    );
    expect(
      gateway.linkTrouble,
      isNotNull,
      reason: 'and it has to say what is actually happening, not go quiet',
    );
    expect(gateway.linkTrouble, contains('not answering'));

    // The cache is not the problem and is not thrown away: what the desktop
    // last sent is still the best thing to show.
    expect(
      (await gateway.watchSessions().first).map((s) => s.id),
      ['s1', 's2'],
    );
  });

  test('one slow answer is still a link — a busy desktop is not a lost one',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    await startService();
    final gateway = await pairedPhone();
    await gateway.listSessions();

    final claimed = <CompanionLinkState>[];
    final watching = gateway.linkStates.listen(claimed.add);
    addTearDown(watching.cancel);

    // Slower than the phone will wait, but not for ever: exactly one call is
    // lost to it.
    fake.stageCost = const Duration(milliseconds: 900);
    await expectLater(
      gateway.listSessions(),
      throwsA(isA<GatewayException>()),
    );
    fake.stageCost = Duration.zero;
    // Everything for one device runs on one chain, so the slow handler has to
    // drain off it before the next request is even read.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect((await gateway.listSessions()).map((s) => s.id), ['s1', 's2']);
    await watching.cancel();

    expect(
      claimed.where((s) => s != CompanionLinkState.connected),
      isEmpty,
      reason: 'one call the desktop was too busy to answer is not an outage',
    );
  });

  test('the owner\'s phone, end to end: a counter bump that never landed no '
      'longer costs the desktop', timeout: const Timeout(Duration(minutes: 3)),
      () async {
    await startService();
    final gateway = await pairedPhone();
    expect((await gateway.listSessions()).map((s) => s.id), ['s1', 's2']);
    await gateway.close();
    gateways.remove(gateway);

    // The counter bump the last connection made never reached the keystore —
    // a write that timed out, or Android killing the app before it landed. So
    // the phone comes back holding the generation it has ALREADY used, and
    // builds a fresh channel on it: the desktop greets it (the hello never
    // goes through a channel) and can then admit nothing it sends.
    rewindStoredGeneration();

    final reopened = makeGateway();
    await awaitLink(reopened, CompanionLinkState.connected);

    // The first call is still lost: the desktop only learns the channel is
    // stale by being handed a frame it cannot open, and that frame is this
    // one. What matters is what happens next.
    await expectLater(
      reopened.listSessions(),
      throwsA(isA<GatewayException>()),
    );
    expect(
      hostLog.where((line) => line.startsWith('retiring generation')),
      isNotEmpty,
      reason: 'the desktop has to notice, say so, and leave the poisoned '
          'generation behind — before this it refused every frame in silence '
          'and the phone waited on it for as long as the app stayed open',
    );

    // Then it heals itself: nobody re-pairs, nobody touches a setting, and
    // everything the owner could not do works.
    await eventually(
      () async {
        try {
          await reopened.listSessions();
          return true;
        } on Object {
          return false;
        }
      },
      reason: 'the phone comes back on the generation the desktop moved to',
    );
    expect((await reopened.listSessions()).map((s) => s.id), ['s1', 's2']);
    expect(reopened.link, CompanionLinkState.connected);
    expect(reopened.linkTrouble, isNull);
  });

  test('the phone that stopped believing itself comes back on its own',
      timeout: const Timeout(Duration(minutes: 3)), () async {
    await startService();
    final gateway = await pairedPhone();
    await gateway.listSessions();

    goSilent();
    for (var i = 0; i < 2; i++) {
      await gateway.listSessions().then<void>(
        (_) {},
        onError: (Object _) {},
      );
    }
    expect(gateway.link, isNot(CompanionLinkState.connected));

    // The desktop finishes whatever held it up. Nobody taps anything.
    fake.stageCost = Duration.zero;
    await awaitLink(gateway, CompanionLinkState.connected);
    expect((await gateway.listSessions()).map((s) => s.id), ['s1', 's2']);
    expect(gateway.linkTrouble, isNull, reason: 'the trouble is over');
  });
}
