import 'dart:async';
import 'dart:typed_data';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/companion/device_links.dart';
import 'package:karmashala_host/src/companion/host_companion.dart';
import 'package:karmashala_host/src/companion/relay_listener.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

/// A box the phone cannot dial is reached through a relay, the way a desktop
/// is. The relay here is the real one on loopback, the phone is the real
/// client, and the host is everything `serve` runs — so what this pins is that
/// the two ends meet, not that each matches a description of the other.
void main() {
  late RelayServer relay;
  late Uri relayUrl;
  late AppDatabase database;
  late PairedDeviceDao devices;
  late SessionRegistry registry;
  late HostCompanion companion;
  late InMemoryCompanionStore phoneStore;
  final dialled = <Uri>[];
  final logs = <String>[];

  setUp(() async {
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUrl = Uri.parse('ws://127.0.0.1:${relay.port}');
    database = AppDatabase.memory();
    devices = PairedDeviceDao(database);
    registry = SessionRegistry(launcher: FakePtyLauncher());
    dialled.clear();
    logs.clear();
    phoneStore = InMemoryCompanionStore();

    final pairing = HostPairingService(
      database: database,
      hostName: 'nat-box',
      hostId: DeviceId.parse('a' * 32),
    );
    final listener = CompanionListener(
      registry: registry,
      hostName: 'nat-box',
      devices: pairing.paired,
      onGeneration: pairing.advance,
      onLog: logs.add,
    );
    await listener.start(address: '127.0.0.1', port: 0);
    companion = HostCompanion(
      pairing: pairing,
      listener: listener,
      onLog: logs.add,
      relayFactory: (url, rendezvous) {
        dialled.add(url);
        return RelayTransport.connect(relay: url, rendezvous: rendezvous);
      },
    );
    await companion.start();
  });

  tearDown(() async {
    await companion.close();
    database.close();
    await relay.close();
  });

  Uint8List secretOf(String code) => PairingCode.tryDecode(code)!;

  /// Pairs the way the phone does for a relay route: the typed code, over the
  /// relay the invite named, and nothing else.
  Future<CompanionPairing> pairThroughRelay() async {
    final window = await companion.openPairing(
      CapabilitySet.all.bits,
      relayUrl.toString(),
    );
    return CompanionPairingClient(
      store: phoneStore,
      deviceId: DeviceId.parse('c' * 32),
      deviceName: 'Pixel 7',
    ).pairWithTypedCode(
      codeSecret: secretOf(window.code),
      relay: relayUrl,
      timeout: const Duration(seconds: 10),
    );
  }

  /// One link through the relay; answers the sessions it read and the record
  /// as the client left it.
  Future<({List<RemoteSessionSnapshot> sessions, CompanionPairing record})>
  linkThroughRelay(CompanionPairing record) async {
    final client = CompanionClient(pairing: record, store: phoneStore);
    try {
      await client.connect(helloTimeout: const Duration(seconds: 10));
      return (sessions: await client.listSessions(), record: client.pairing);
    } finally {
      await client.close();
    }
  }

  Future<void> settle(bool Function() done) => Future.doWhile(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return !done();
  }).timeout(const Duration(seconds: 10));

  test('a direct pairing dials nothing and names no relay', () async {
    final window = await companion.openPairing(CapabilitySet.all.bits, '');

    await CompanionPairingClient(
      store: phoneStore,
      deviceId: DeviceId.parse('c' * 32),
      deviceName: 'Pixel 7',
    ).pairWithTypedCode(
      codeSecret: secretOf(window.code),
      relay: Uri.parse('https://unused.invalid'),
      transport: LanTransport(host: '127.0.0.1', port: companion.listener.port)
        ..start(),
      timeout: const Duration(seconds: 10),
    );
    await companion.relays.sync();

    expect(devices.getActive().single.relayUrl, isNull);
    expect(dialled, isEmpty, reason: 'a box with its own address calls nobody');
    expect(companion.relays.listenerCount, 0);
    expect(relay.rendezvousCount, 0);
  });

  test(
    'a relay pairing happens through the relay and is written on the row',
    () async {
      final record = await pairThroughRelay();

      expect(record.hostName, 'nat-box');
      expect(devices.getActive().single.relayUrl, relayUrl.toString());
      expect(devices.getActive().single.name, 'Pixel 7');
      // The window's own link is gone, and the phone's listeners are up instead.
      await settle(
        () => companion.relays.listenerCount == kHostGenerationWindow,
      );
      expect(dialled.toSet(), {relayUrl});
    },
  );

  test(
    'a relay-route phone reads this machine\'s sessions, and comes back',
    () async {
      registry.open(
        'karmashala_live',
        const PtySpawnRequest(
          argv: ['claude'],
          workingDirectory: '/srv/app',
          environment: {},
          columns: 80,
          rows: 24,
        ),
      );
      final record = await pairThroughRelay();
      await settle(
        () => companion.relays.listenerCount == kHostGenerationWindow,
      );

      final first = await linkThroughRelay(record);
      expect(first.sessions.single.sessionId, 'karmashala_live');
      expect(first.record.generation, record.generation + 1);

      // Every dial after that is a different rendezvous, and past the third it is
      // one that was not open when the phone paired: the window has to have
      // moved, and the row with it.
      var latest = first.record;
      for (var i = 0; i < kHostGenerationWindow + 1; i++) {
        final next = await linkThroughRelay(latest);
        expect(next.sessions.single.sessionId, 'karmashala_live');
        latest = next.record;
      }
      expect(devices.getActive().single.generation, latest.generation);
      expect(latest.generation, record.generation + kHostGenerationWindow + 2);

      // A served generation is let go once its phone has left, so an idle box
      // holds a window's worth of sockets and no more.
      await settle(
        () => companion.relays.listenerCount == kHostGenerationWindow,
      );
    },
  );

  test('a revoked phone is not waited for', () async {
    await pairThroughRelay();
    await settle(() => companion.relays.listenerCount == kHostGenerationWindow);

    devices.revoke(devices.getActive().single.id);
    await companion.relays.sync();

    expect(companion.relays.listenerCount, 0);
    await settle(() => relay.rendezvousCount == 0);
  });

  test('a host that restarts waits for the phones it already has', () async {
    final record = await pairThroughRelay();
    await companion.relays.stop();

    // What `serve` builds on the way up, over the same store.
    final again = RelayListener(links: companion.listener.links);
    addTearDown(again.stop);
    await again.sync();
    expect(again.listenerCount, kHostGenerationWindow);

    final client = CompanionClient(pairing: record, store: phoneStore);
    addTearDown(client.close);
    await client.connect(helloTimeout: const Duration(seconds: 10));
    expect(await client.listSessions(), isEmpty);
  });

  test(
    'a relay this host cannot dial is refused, not paired the other way',
    () async {
      await expectLater(
        companion.openPairing(CapabilitySet.all.bits, 'ftp://relay.example'),
        throwsFormatException,
      );
      expect(dialled, isEmpty);
    },
  );

  test('a second window closes the first one\'s relay link', () async {
    await companion.openPairing(CapabilitySet.all.bits, relayUrl.toString());
    await settle(() => relay.rendezvousCount == 1);

    await companion.openPairing(CapabilitySet.all.bits, relayUrl.toString());

    await settle(() => relay.rendezvousCount == 1);
    expect(dialled, hasLength(2));
  });

  test('nothing logged names a rendezvous, a key or a code', () async {
    final window = await companion.openPairing(
      CapabilitySet.all.bits,
      relayUrl.toString(),
    );
    final record =
        await CompanionPairingClient(
          store: phoneStore,
          deviceId: DeviceId.parse('c' * 32),
        ).pairWithTypedCode(
          codeSecret: secretOf(window.code),
          relay: relayUrl,
          timeout: const Duration(seconds: 10),
        );
    await linkThroughRelay(record);

    final said = logs.join('\n');
    expect(said, isNot(contains(window.code)));
    expect(said, isNot(matches(RegExp('[0-9a-f]{32}'))));
  });

  test('usableRelay knows a desktop\'s "local" is not a place', () {
    expect(usableRelay(null), isNull);
    expect(usableRelay(''), isNull);
    expect(usableRelay(kLocalRelayMarker), isNull);
    expect(usableRelay('ftp://relay.example'), isNull);
    expect(
      usableRelay('wss://relay.example'),
      Uri.parse('wss://relay.example'),
    );
  });
}
