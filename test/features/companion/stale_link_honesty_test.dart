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

import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/companion/client/companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/remote_companion_gateway.dart';
import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/remote/transport/relay_transport.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
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
  Completer<void>? busy;

  /// A desktop that keeps the socket but stops answering: every `sessions.list`
  /// now waits on a gate this test holds.
  ///
  /// It used to be `stageCost = 30s`, out-waited by the phone's 700ms request
  /// timeout. That works, but nothing releases it: the calls the phone
  /// abandoned still sat on the desktop's single per-device chain for the
  /// full thirty seconds, so the "it heals on its own" case below had to find
  /// its way home inside whatever was left of its budget. On a loaded machine
  /// it did not, roughly one run in three. A gate ends the silence the moment
  /// the test says the desktop is back.
  void goSilent() => busy = fake.stageGate = Completer<void>();

  /// The desktop finishes whatever held it up, at once.
  void answerAgain() {
    fake.stageGate = null;
    final held = busy;
    busy = null;
    if (held != null && !held.isCompleted) held.complete();
  }

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
    // A gate still held would deadlock the shutdown as surely as it holds the
    // desktop.
    answerAgain();
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
    final session = await service!.beginPairing(
      capabilities: CapabilitySet.all,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
    return gateway;
  }

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

  test(
    'a phone left with only a cached list does not call itself connected',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
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
        reason:
            'every live request timed out; "connected" is not a true thing '
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
      expect((await gateway.watchSessions().first).map((s) => s.id), [
        's1',
        's2',
      ]);
    },
  );

  test(
    'one slow answer is still a link — a busy desktop is not a lost one',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      await startService();
      final gateway = await pairedPhone();
      await gateway.listSessions();

      final claimed = <CompanionLinkState>[];
      final watching = gateway.linkStates.listen(claimed.add);
      addTearDown(watching.cancel);

      // Exactly one call is lost to a desktop too busy to answer it, and this
      // test says when it comes back. It used to be a 900ms handler racing a
      // 700ms request timeout with 200ms between them, and then a three-second
      // sleep to let the abandoned handler drain off the device's single
      // chain — during which a second lost call would land in `claimed` and
      // fail the assertion below over nothing.
      goSilent();
      await expectLater(
        gateway.listSessions(),
        throwsA(isA<GatewayException>()),
      );

      // The claim, checked at the only moment it means anything: right after
      // the busy call, with nothing else having been asked for in between.
      await watching.cancel();
      expect(
        claimed.where((s) => s != CompanionLinkState.connected),
        isEmpty,
        reason: 'one call the desktop was too busy to answer is not an outage',
      );

      // And it is still a working link: the desktop gets free and the phone
      // has its list, with nobody touching anything.
      answerAgain();
      await eventually(() async {
        try {
          await gateway.listSessions();
          return true;
        } on Object {
          return false;
        }
      }, reason: 'the desktop answers again once it is no longer busy');
      expect((await gateway.listSessions()).map((s) => s.id), ['s1', 's2']);
    },
  );

  test(
    'the owner\'s phone, end to end: a counter bump that never landed no '
    'longer costs the desktop',
    timeout: const Timeout(Duration(minutes: 3)),
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
        reason:
            'the desktop has to notice, say so, and leave the poisoned '
            'generation behind — before this it refused every frame in silence '
            'and the phone waited on it for as long as the app stayed open',
      );

      // Then it heals itself: nobody re-pairs, nobody touches a setting, and
      // everything the owner could not do works.
      await eventually(() async {
        try {
          await reopened.listSessions();
          return true;
        } on Object {
          return false;
        }
      }, reason: 'the phone comes back on the generation the desktop moved to');
      expect((await reopened.listSessions()).map((s) => s.id), ['s1', 's2']);
      expect(reopened.link, CompanionLinkState.connected);
      expect(reopened.linkTrouble, isNull);
    },
  );

  test(
    'the phone that stopped believing itself comes back on its own',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      await startService();
      final gateway = await pairedPhone();
      await gateway.listSessions();

      goSilent();
      for (var i = 0; i < 2; i++) {
        await gateway.listSessions().then<void>((_) {}, onError: (Object _) {});
      }
      expect(gateway.link, isNot(CompanionLinkState.connected));

      // The desktop finishes whatever held it up. Nobody taps anything.
      answerAgain();
      await awaitLink(gateway, CompanionLinkState.connected);
      // `eventually`, like the sibling case above, and for the same reason: what
      // is promised is that the phone comes back on its own, not that the very
      // first request after the first `connected` edge lands. A link may still
      // drop once more between the two — `_requireClient` re-declares it dead and
      // the loop re-dials — and on a loaded machine it intermittently did,
      // failing this case roughly one run in three while the behaviour under test
      // was fine.
      await eventually(() async {
        try {
          await gateway.listSessions();
          return true;
        } on Object {
          return false;
        }
      }, reason: 'the phone comes back with nobody touching it');
      expect((await gateway.listSessions()).map((s) => s.id), ['s1', 's2']);
      expect(gateway.linkTrouble, isNull, reason: 'the trouble is over');
    },
  );

  test(
    'a request the desktop did not answer says so, not "unreachable"',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      await startService();
      final gateway = await pairedPhone();
      expect((await gateway.listSessions()).map((s) => s.id), ['s1', 's2']);

      goSilent();

      // The owner's own objection, in their words: "this did not work host is
      // unreachable now. which is not the case host is here this session is
      // running on the host" — said while the status bar beside it still read
      // "running here". Both halves of the old sentence were false for a
      // timeout: the host is demonstrably reachable, because the link is
      // carrying frames, and the request *was* sent. Only the answer is
      // missing.
      await expectLater(
        gateway.listSessions(),
        throwsA(
          isA<GatewayException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('did not answer'),
              contains('busy'),
              isNot(contains('unreachable')),
              isNot(contains('nothing was sent')),
            ),
          ),
        ),
      );
    },
  );
}
