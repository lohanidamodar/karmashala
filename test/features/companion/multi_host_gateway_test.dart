/// Two desktops, one phone. The real [RemoteCompanionGateway] against TWO
/// in-process hosts — separate databases, separate bindings, separate host
/// ids, one shared relay — so pairing-adds, switching and per-host removal are
/// proven on the wire rather than against a script.
///
/// Every case here pairs at least once over a real socket, and the default
/// per-test budget of thirty seconds sat only ten seconds above the pairing
/// timeout it has to contain. Under `--concurrency=4` that is not enough
/// room, and this file was one of the five that fail together and pass alone.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala_remote/companion.dart';
import 'package:karmashala/src/features/companion/client/secure_companion_store.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_remote/client.dart'
    as stored;
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../remote/fake_bindings.dart';
import '../remote/transport_harness.dart';

/// One desktop: its own database, bindings and running host service.
class _Host {
  _Host(this.db, this.dao, this.fake, this.service);

  final AppDatabase db;
  final PairedDeviceDao dao;
  final FakeRemoteBindings fake;
  final RemoteHostService service;

  Future<void> dispose() async {
    await service.stop();
    db.close();
  }
}

void main() {
  late RelayServer relay;
  late Uri relayUri;
  late Map<String, String> phoneDisk;
  late SecureCompanionStore store;
  /// Set, every keystore write hangs — which is how a real one fails when it
  /// fails worst. [SecureCompanionStore] turns that into a `TimeoutException`
  /// rather than holding the mutation chain open for the life of the process.
  var writesHang = false;

  /// Set to a host id, the write that makes a freshly paired desktop the
  /// ACTIVE one hangs. That mirror write is the one keystore call in a
  /// pairing that belongs to the gateway rather than to the pairing client.
  String? hangOnActiveHost;
  final hosts = <_Host>[];
  final gateways = <RemoteCompanionGateway>[];

  setUp(() async {
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    // Loop 83's last-resort relay is the phone's configured one, which
    // defaults to the public PopupBits relay — point it here instead.
    phoneDisk = {
      RemoteCompanionGateway.kPairingRelayStoreKey: relayUri.toString(),
    };
    writesHang = false;
    hangOnActiveHost = null;
    store = SecureCompanionStore.withBackend(
      read: (key) async => phoneDisk[key],
      write: (key, value) async {
        final active = hangOnActiveHost;
        if (writesHang ||
            (active != null &&
                key == stored.CompanionPairing.storeKey &&
                value.contains(active))) {
          await Completer<void>().future;
        }
        phoneDisk[key] = value;
      },
      delete: (key) async {
        if (writesHang) await Completer<void>().future;
        phoneDisk.remove(key);
      },
      timeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    writesHang = false;
    hangOnActiveHost = null;
    for (final gateway in gateways.reversed.toList()) {
      await gateway.close();
    }
    gateways.clear();
    for (final host in hosts.reversed.toList()) {
      await host.dispose();
    }
    hosts.clear();
    await relay.close();
  });

  /// A desktop of its own, named by [hostId], holding one session.
  Future<_Host> startHost({
    required String hostId,
    required String sessionId,
    required String title,
  }) async {
    final db = AppDatabase.memory();
    final dao = PairedDeviceDao(db);
    final fake = FakeRemoteBindings()..addSession(sessionId, title: title);
    fake.transcripts[sessionId] = [
      RemoteTranscriptMessage(role: 'agent', text: 'from $title'),
    ];
    final service = RemoteHostService(
      devices: dao,
      hostId: DeviceId.parse(hostId),
      bindings: fake.bindings,
      relay: relayUri,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    await service.start();
    final host = _Host(db, dao, fake, service);
    hosts.add(host);
    return host;
  }

  RemoteCompanionGateway makeGateway() {
    final gateway = RemoteCompanionGateway(
      store: store,
      deviceModel: 'Test phone',
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
      requestTimeout: const Duration(seconds: 2),
      helloTimeout: const Duration(seconds: 2),
      // Spelled out rather than left on the production default of 20s. That
      // default is what a phone on a real network should wait for a hosted
      // relay; every pairing here is in-process over loopback, and none of
      // these tests measures pairing latency — so a 20s cap was only an extra
      // way for a loaded machine to fail them, as `TimeoutException after
      // 0:00:20` out of `_pairOverAnyPath`, on a run where nothing was wrong.
      pairingTimeout: const Duration(seconds: 90),
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

  Future<void> pairWith(RemoteCompanionGateway gateway, _Host host) async {
    final session = await host.service.beginPairing(
      capabilities: CapabilitySet.all,
    );
    await gateway.pairWithQr(session.payload.encode());
    await session.done;
    await awaitLink(gateway, CompanionLinkState.connected);
  }

  /// Ten seconds was the budget here, which is a guess about how loaded the
  /// machine is rather than a claim about the code. Thirty is the same claim
  /// with room for `--concurrency=4`.
  Future<void> eventually(
    Future<bool> Function() check, {
    Duration timeout = const Duration(seconds: 30),
    String reason = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (await check()) return;
      if (DateTime.now().isAfter(deadline)) fail('never happened: $reason');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  const idA = '11111111222222223333333344444444';
  const idB = 'aaaaaaaabbbbbbbbccccccccdddddddd';

  test('the whole multi-host story: pair one desktop, pair a second WITHOUT '
      'losing the first, switch between them with no state bleed', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();

    // Unpaired: no connections at all.
    expect(await gateway.connectionsStates.first, isEmpty);

    // Desktop one.
    await pairWith(gateway, studio);
    expect(gateway.connections, hasLength(1));
    expect(gateway.connections.single.hostId, idA);
    expect(gateway.connections.single.active, isTrue);
    expect((await gateway.listSessions()).single.title, 'Studio work');

    // Desktop two — the phone is already paired, so this ADDS and switches.
    await pairWith(gateway, laptop);
    expect(
      gateway.connections,
      hasLength(2),
      reason: 'pairing a second desktop must not replace the first',
    );
    expect(
      {for (final c in gateway.connections) c.hostId},
      {idA, idB},
      reason: 'both desktops are saved',
    );
    expect(
      gateway.connections.singleWhere((c) => c.active).hostId,
      idB,
      reason: 'a freshly paired desktop becomes the active one',
    );
    await eventually(
      () async => (await gateway.listSessions()).single.title == 'Laptop work',
      reason: "the list is the new host's",
    );

    // Both records really are on the phone's disk.
    final saved = await stored.CompanionConnections.load(store);
    expect({for (final r in saved.records) r.hostId.value}, {idA, idB});

    // Switch back — and nothing of the laptop's may survive it.
    final laptopSessions = await gateway.listSessions();
    expect(laptopSessions.single.id, 's-laptop');

    await gateway.switchTo(idA);
    await awaitLink(gateway, CompanionLinkState.connected);

    expect(gateway.connections.singleWhere((c) => c.active).hostId, idA);
    expect(gateway.pairing?.hostId?.value, idA);
    await eventually(() async {
      final list = await gateway.watchSessions().first;
      return list.length == 1 && list.single.id == 's-studio';
    }, reason: "the studio's list replaced the laptop's entirely");
    final afterSwitch = await gateway.listSessions();
    expect(
      [for (final s in afterSwitch) s.id],
      ['s-studio'],
      reason: 'no laptop session bled through the switch',
    );

    // Transcripts are per host too: the studio's stream must not replay the
    // laptop's rows.
    final transcript = await gateway.transcript('s-studio').firstWhere(
      (rows) => rows.isNotEmpty,
    );
    expect([for (final m in transcript) m.text], ['from Studio work']);

    // And the prompt goes to the desktop we are actually on.
    await gateway.sendPrompt('s-studio', 'carry on');
    expect(studio.fake.prompts, [
      (sessionId: 's-studio', text: 'carry on'),
    ]);
    expect(
      laptop.fake.prompts,
      isEmpty,
      reason: 'the host we switched away from hears nothing',
    );
  });

  test('re-pairing the SAME desktop replaces its record and leaves the '
      'other alone', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await pairWith(gateway, laptop);
    expect(gateway.connections, hasLength(2));

    // Pair with the studio again — a user re-scanning its QR.
    await pairWith(gateway, studio);

    expect(
      gateway.connections,
      hasLength(2),
      reason: 're-pairing a known host must not add a duplicate row',
    );
    expect(gateway.connections.singleWhere((c) => c.active).hostId, idA);
    final saved = await stored.CompanionConnections.load(store);
    expect(saved.records, hasLength(2));
  });

  test('removing a background desktop keeps the live link untouched', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await pairWith(gateway, laptop);

    await gateway.removeConnection(idA);

    expect(gateway.connections.single.hostId, idB);
    expect(gateway.connections.single.active, isTrue);
    expect(
      gateway.link,
      CompanionLinkState.connected,
      reason: 'forgetting another desktop must not disturb this one',
    );
    expect((await gateway.listSessions()).single.id, 's-laptop');
    final saved = await stored.CompanionConnections.load(store);
    expect(saved.records.single.hostId.value, idB);
  });

  test('removing the ACTIVE desktop falls back to the other one and '
      'connects to it', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await pairWith(gateway, laptop);
    expect(gateway.connections.singleWhere((c) => c.active).hostId, idB);

    await gateway.removeConnection(idB);

    expect(gateway.connections.single.hostId, idA);
    expect(gateway.connections.single.active, isTrue);
    await awaitLink(gateway, CompanionLinkState.connected);
    expect((await gateway.listSessions()).single.id, 's-studio');
  });

  test('a keystore that stops answering refuses the switch in words, and '
      'leaves the link it has alone', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await pairWith(gateway, laptop);

    // Nothing the phone writes lands from here. The switch cannot happen —
    // but it has to SAY so: a refusal that escapes as an unhandled async
    // error is a tap that did nothing, with no message anywhere.
    writesHang = true;
    await expectLater(
      gateway.switchTo(idA),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.message,
          'message',
          contains('Try again'),
        ),
      ),
    );
    await expectLater(
      gateway.setPairingRelay(Uri.parse('wss://elsewhere.example')),
      throwsA(isA<GatewayException>()),
      reason: 'the same for the relay setting: refused, not silently lost',
    );

    writesHang = false;
    expect(
      gateway.connections.singleWhere((c) => c.active).hostId,
      idB,
      reason: 'the desktop it was on is the desktop it is still on',
    );
    expect(gateway.link, CompanionLinkState.connected);
    expect((await gateway.listSessions()).single.id, 's-laptop');
  });

  test('a pairing this phone cannot record as the active one fails out loud',
      () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);

    // The desktop confirms; what fails is the phone writing down which
    // desktop to use from now on. Escaping from there is an unhandled async
    // error and a pairing screen that never moves off "proving".
    hangOnActiveHost = idB;
    final session = await laptop.service.beginPairing(
      capabilities: CapabilitySet.all,
    );
    await expectLater(
      gateway.pairWithQr(session.payload.encode()),
      throwsA(isA<PairingException>()),
    );
    await session.done;
    hangOnActiveHost = null;
  });

  test('removing the LAST desktop leaves the phone unpaired', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);

    await gateway.removeConnection(idA);

    expect(gateway.connections, isEmpty);
    expect(gateway.pairing, isNull);
    expect(gateway.link, CompanionLinkState.disconnected);
    expect(gateway.capabilities, CapabilitySet.none);
    await expectLater(
      gateway.listSessions(),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.message,
          'message',
          contains('not paired'),
        ),
      ),
    );
  });

  test('unpair forgets the ACTIVE desktop and lands on the other', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await pairWith(gateway, laptop);

    await gateway.unpair();

    expect(gateway.connections.single.hostId, idA);
    expect(gateway.pairing, isNotNull, reason: 'still paired — with the other');
    await awaitLink(gateway, CompanionLinkState.connected);
  });

  test('a relaunch comes back on the desktop that was active, with both '
      'still saved', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final first = makeGateway();
    await pairWith(first, studio);
    await pairWith(first, laptop);
    await first.switchTo(idA);
    await awaitLink(first, CompanionLinkState.connected);
    await first.close();

    final again = makeGateway();
    await again.connectionsStates
        .firstWhere((list) => list.isNotEmpty)
        .timeout(const Duration(seconds: 5));

    expect(again.connections, hasLength(2));
    expect(again.connections.singleWhere((c) => c.active).hostId, idA);
    await awaitLink(again, CompanionLinkState.connected);
    expect((await again.listSessions()).single.id, 's-studio');
  });

  test('switching to a host this phone does not hold is refused in words, '
      'and the live link is left alone', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);

    await expectLater(
      gateway.switchTo('ffffffffffffffffffffffffffffffff'),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.message,
          'message',
          contains('no longer saved'),
        ),
      ),
    );
    expect(gateway.link, CompanionLinkState.connected);
    expect(gateway.connections.single.active, isTrue);
  });

  test('switching to a desktop that is not answering lands on it '
      'disconnected — never silently back on the old one', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await pairWith(gateway, laptop);
    // The studio goes away entirely — the machine is off.
    await studio.service.stop();

    await gateway.switchTo(idA);

    // The phone is ON the chosen desktop, and honest about not reaching it.
    expect(gateway.connections.singleWhere((c) => c.active).hostId, idA);
    expect(gateway.pairing?.hostId?.value, idA);
    await eventually(
      () async => gateway.link != CompanionLinkState.connected,
      reason: 'the link does not claim to be up',
    );
    await expectLater(
      gateway.listSessions(),
      throwsA(
        isA<GatewayException>().having(
          (e) => e.message,
          'message',
          contains('unreachable'),
        ),
      ),
    );
  });

  test('the trouble sentence belongs to the desktop that produced it, and '
      'does not follow the phone to the next one', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await pairWith(gateway, laptop);

    // The studio goes dark, so the phone builds up a sentence about IT.
    await studio.service.stop();
    await gateway.switchTo(idA);
    await eventually(
      () async => await gateway.linkTroubleStates.first != null,
      reason: 'the phone has something to say about the studio',
    );

    // Back to the laptop, which is up. `linkTroubleStates` is the raw cell the
    // banner reads — unlike the `linkTrouble` getter it is not gated on the
    // link being down — so a sentence left in it here is rendered under the
    // laptop's name, as the laptop's problem, before the laptop has been asked
    // anything.
    await gateway.switchTo(idB);

    expect(
      await gateway.linkTroubleStates.first,
      isNull,
      reason: "the studio's problem is not the laptop's",
    );
  });

  test('attention events carry the host they came from', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final gateway = makeGateway();
    await pairWith(gateway, studio);
    await gateway.listSessions();

    final events = ItemQueue(gateway.attentionEvents);
    studio.fake.sessions['s-studio'] = studio.fake.sessions['s-studio']!
        .copyWith(attention: 'needs_approval');
    await studio.service.notifySessionsChanged();

    final event = await events.next;
    expect(event.sessionId, 's-studio');
    expect(
      event.hostId,
      idA,
      reason: 'the notification knows which desktop it is about',
    );
    await events.cancel();
  });

  test('last-connected is stamped, so the Connections list can order and '
      'label the saved desktops', () async {
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final gateway = makeGateway();
    expect(gateway.connections, isEmpty);

    await pairWith(gateway, studio);

    await eventually(
      () async => gateway.connections.single.lastConnectedAt != null,
      reason: 'a connected desktop records when it was reached',
    );
    final saved = await stored.CompanionConnections.load(store);
    expect(saved.records.single.lastConnectedAt, isNotNull);
  });

  test('a relaunch restores the saved SET and reconnects to the active '
      'desktop, with nothing left in memory to help it', () async {
    // The bug this pins: a phone pairs, the app is killed, and on the next
    // launch it neither remembers the desktop nor connects. Everything below
    // the gateway is real — the secure store over a persistent backend, both
    // storage keys, two records — and every object that saw the pairing is
    // thrown away before the "relaunch".
    final studio = await startHost(
      hostId: idA,
      sessionId: 's-studio',
      title: 'Studio work',
    );
    final laptop = await startHost(
      hostId: idB,
      sessionId: 's-laptop',
      title: 'Laptop work',
    );
    final first = makeGateway();
    await pairWith(first, studio);
    await pairWith(first, laptop);
    await first.close();

    // Both keys are on "disk", the way a real phone's keystore holds them.
    expect(phoneDisk, contains(stored.CompanionConnections.storeKey));
    expect(phoneDisk, contains(stored.CompanionPairing.storeKey));

    // The relaunch: a brand-new store object over the same bytes, and a
    // brand-new gateway over that. No in-memory state survives.
    store = SecureCompanionStore.withBackend(
      read: (key) async => phoneDisk[key],
      write: (key, value) async => phoneDisk[key] = value,
      delete: (key) async => phoneDisk.remove(key),
    );
    final again = makeGateway();

    expect(
      await again.pairingStates
          .firstWhere((pairing) => pairing != null)
          .timeout(const Duration(seconds: 5)),
      isNotNull,
      reason: 'the phone remembers the desktop it paired with',
    );
    // It dials on its own — no tap, no re-pair.
    await awaitLink(again, CompanionLinkState.connected);
    expect(again.connections, hasLength(2), reason: 'the whole set survives');
    expect(again.connections.singleWhere((c) => c.active).hostId, idB);
    expect((await again.listSessions()).single.title, 'Laptop work');
  });

  test('a keystore that fails outright leaves the phone unpaired but '
      'ALIVE — never a launch that half-works', () async {
    // What a rotated Android master key looks like from here: reads throw.
    // `SecureCompanionStore` turns that into null, but nothing below it
    // should be able to poison the launch either.
    final gateway = RemoteCompanionGateway(
      store: _ThrowingStore(),
      deviceModel: 'Test phone',
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
      )..start(),
      requestTimeout: const Duration(milliseconds: 200),
      helloTimeout: const Duration(milliseconds: 200),
      reconnectBackoff: fastBackoff(),
    );
    gateways.add(gateway);

    expect(await gateway.pairingStates.first, isNull);
    expect(gateway.connections, isEmpty);
    // Usable, not wedged: the refusal is the gateway's own sentence about
    // being unpaired, not a storage error escaping from the constructor.
    await expectLater(
      gateway.listSessions(),
      throwsA(isA<GatewayException>()),
    );
  });
}

/// A store whose every read fails — the platform keystore refusing to
/// decrypt what it holds.
class _ThrowingStore implements stored.CompanionStore {
  @override
  Future<String?> read(String key) async => throw StateError('keystore says no');

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
