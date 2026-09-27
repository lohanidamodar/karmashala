/// The LAN relay is the server's (slice 5c follow-up, protocol 29). Found
/// live: a phone paired through the relay on port 8787, which ran inside the
/// desktop app, said "Host unreachable — This phone could not reach the relay
/// the machine uses" whenever the app was closed, although the server kept
/// serving on its own. Here there is no app anywhere: the server hosts the
/// relay, listens through it, and a phone's real companion client reaches it
/// there — freshly paired, and on a pairing made before, by the same route.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_companion_server/store.dart' show hostDeviceIdFor;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12);
  final deviceKey = Uint8List.fromList(List.generate(32, (i) => i + 3));

  late AppDatabase database;
  late SessionRegistry registry;
  late StreamController<LifecycleEvent> events;
  final companions = <DaemonCompanion>[];

  setUp(() {
    database = AppDatabase.memory();
    registry = SessionRegistry(launcher: FakePtyLauncher());
    events = StreamController<LifecycleEvent>.broadcast();
  });

  tearDown(() async {
    for (final companion in companions.reversed) {
      await companion.close();
    }
    companions.clear();
    await events.close();
    await registry.shutdown();
    database.close();
  });

  /// A server's companion as `serve` builds it from `server.json`
  /// `{"companion": {"enabled": true, "localRelay": true, …}}` — on loopback,
  /// and never on 8787: the owner's own server may hold it.
  Future<DaemonCompanion> serve({int relayPort = 0}) async {
    final companion = DaemonCompanion(
      database: database,
      registry: registry,
      hostName: 'desk',
      lanPort: 0,
      config: const CompanionConfig(enabled: true),
      localRelayEnabled: true,
      localRelayPort: relayPort,
      transcriptPollInterval: Duration.zero,
    );
    companions.add(companion);
    await companion.start(sessionEvents: events.stream);
    return companion;
  }

  /// A phone's record, as a phone paired through the local relay keeps it:
  /// the relay it met the machine at, nothing else.
  CompanionPairing phoneRecord(Uri relay, {int generation = 0}) =>
      CompanionPairing(
        hostId: hostDeviceIdFor(database),
        deviceId: DeviceId.parse('d' * 32),
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        relay: relay,
        generation: generation,
        hostName: 'desk',
      );

  void insertLocalRelayPairing() => PairedDeviceDao(database).insert(
    PairedDevice(
      id: 'd' * 32,
      name: 'Pixel',
      deviceKey: deviceKey,
      capabilities: CapabilitySet.all,
      generation: 0,
      createdAt: t0,
      // What a pairing through "Local network" has always recorded.
      relayUrl: kLocalRelayMarker,
    ),
  );

  test('the relay runs in the server and the server listens through it: a '
      'phone paired there reaches it with no app anywhere', () async {
    insertLocalRelayPairing();
    final companion = await serve();
    final url = companion.localRelayStatus.primaryUrl!;
    expect(companion.config.localRelayUrl, url);
    expect(companion.service!.isParked('d' * 32), isFalse);

    final client = CompanionClient(
      pairing: phoneRecord(url),
      store: InMemoryCompanionStore(),
    );
    addTearDown(client.close);
    // No transport: the client dials its record's relay, as the phone does.
    final status = await client.connect(
      helloTimeout: const Duration(seconds: 10),
    );

    expect(status.relays, contains(url), reason: 'announced where it waits');
    expect(await client.listSessions(), isEmpty);
  });

  test('a pairing opened at the local relay is met there, recorded as the '
      'local relay, and served through it', () async {
    final companion = await serve();
    final url = companion.localRelayStatus.primaryUrl!;

    final window = await companion.openPairing(
      capabilities: CapabilitySet.all.bits,
      // Where the desktop's tab said; the server decides the URL itself.
      relay: '',
      relayIsLocal: true,
    );
    final payload = PairingPayload.decode(window.payload);
    expect(payload.relay, url);

    final store = InMemoryCompanionStore();
    final paired = await CompanionPairingClient(
      store: store,
      deviceName: 'Phone',
    ).pair(payload);
    final deviceId = await window.paired;
    expect(
      PairedDeviceDao(database).getById(deviceId)!.relayUrl,
      kLocalRelayMarker,
    );

    final client = CompanionClient(pairing: paired, store: store);
    addTearDown(client.close);
    await client.connect(helloTimeout: const Duration(seconds: 10));
    expect(await client.listSessions(), isEmpty);
  });

  test(
    'the same route is served by a restarted server: no re-pairing',
    () async {
      insertLocalRelayPairing();
      final first = await serve();
      final url = first.localRelayStatus.primaryUrl!;
      final store = InMemoryCompanionStore();
      final before = CompanionClient(pairing: phoneRecord(url), store: store);
      await before.connect(helloTimeout: const Duration(seconds: 10));
      final next = before.pairing;
      await before.close();
      await first.close();
      companions.remove(first);

      // The port the phone has saved, now held by a new server process.
      final second = await serve(relayPort: url.port);
      expect(second.localRelayStatus.primaryUrl, url);
      final after = CompanionClient(pairing: next, store: store);
      addTearDown(after.close);
      await after.connect(helloTimeout: const Duration(seconds: 10));
      expect(await after.listSessions(), isEmpty);
    },
  );

  test('switched off in the config, it stops; on again, it serves; with '
      'remote access off, nothing listens', () async {
    final companion = await serve();
    expect(companion.localRelayStatus.running, isTrue);

    await companion.reconfigure(
      config: const CompanionConfig(enabled: true),
      lanAddress: '127.0.0.1',
      lanPort: 0,
    );
    expect(companion.localRelayStatus.state, LocalRelayState.stopped);
    expect(companion.config.localRelayUrl, isNull);
    expect(companion.service, isNotNull, reason: 'the LAN listener serves on');

    await companion.reconfigure(
      config: const CompanionConfig(enabled: true),
      lanAddress: '127.0.0.1',
      lanPort: 0,
      localRelayEnabled: true,
      localRelayPort: 0,
    );
    expect(companion.localRelayStatus.running, isTrue);
    expect(companion.config.localRelayUrl, isNotNull);

    await companion.reconfigure(
      config: CompanionConfig.off,
      lanAddress: '127.0.0.1',
      lanPort: 0,
      localRelayEnabled: true,
      localRelayPort: 0,
    );
    expect(companion.localRelayStatus.state, LocalRelayState.stopped);
    expect(companion.service, isNull);
  });

  test(
    'a pairing at the local relay while it is off is refused in words',
    () async {
      final companion = DaemonCompanion(
        database: database,
        registry: registry,
        hostName: 'desk',
        lanPort: 0,
        config: const CompanionConfig(enabled: true),
        transcriptPollInterval: Duration.zero,
      );
      companions.add(companion);
      await companion.start(sessionEvents: events.stream);

      await expectLater(
        companion.openPairing(
          capabilities: CapabilitySet.all.bits,
          relay: '',
          relayIsLocal: true,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('local relay is not running'),
          ),
        ),
      );
    },
  );

  test(
    'a taken port is the relay\'s status, not the companion\'s failure',
    () async {
      final taken = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(taken.close);
      final companion = await serve(relayPort: taken.port);

      expect(companion.localRelayStatus.state, LocalRelayState.error);
      expect(companion.localRelayStatus.error, contains('in use'));
      expect(companion.service, isNotNull, reason: 'the LAN listener serves');
      expect(companion.config.localRelayUrl, isNull);
    },
  );

  test('bound to the LAN, the direct listener is announced as a hint without '
      'any relay', () async {
    PairedDeviceDao(database).insert(
      PairedDevice(
        id: 'd' * 32,
        name: 'Pixel',
        deviceKey: deviceKey,
        capabilities: CapabilitySet.all,
        generation: 0,
        createdAt: t0,
      ),
    );
    final companion = DaemonCompanion(
      database: database,
      registry: registry,
      hostName: 'desk',
      lanPort: 0,
      // Only ever dialled on loopback below; the hint is what is under test.
      lanAddress: '0.0.0.0',
      lanInterfaces: () async => [
        (name: 'vEthernet (WSL)', ip: '172.22.32.1'),
        (name: 'en0', ip: '192.168.1.7'),
      ],
      config: const CompanionConfig(enabled: true),
      transcriptPollInterval: Duration.zero,
    );
    companions.add(companion);
    await companion.start(sessionEvents: events.stream);

    final client = CompanionClient(
      pairing: phoneRecord(Uri.parse('https://unused.invalid')),
      store: InMemoryCompanionStore(),
    );
    addTearDown(client.close);
    final status = await client.connect(
      transport: LanTransport(host: '127.0.0.1', port: companion.port!)
        ..start(),
      helloTimeout: const Duration(seconds: 10),
    );
    expect(status.lanHint, '192.168.1.7:${companion.port}');
  });
}
