/// The whole host service, end to end over real sockets on 127.0.0.1: LAN
/// links routed by hello, relay listeners against an in-process relay, the
/// generation window, revocation, and the event fan-out — with the companion
/// client on the other end.
library;

import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_store/devices.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:test/test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  late RemoteHostService service;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
  });

  tearDown(() async {
    for (final cleanup in cleanups.reversed.toList()) {
      await cleanup();
    }
    cleanups.clear();
    await service.stop();
    await relay.close();
    db.close();
  });

  Future<Uint8List> deviceKey() async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: _deviceId,
    )).bytes,
  );

  Future<void> pairDevice({int generation = kFirstSessionGeneration}) async {
    dao.insert(
      PairedDevice(
        id: _deviceId.value,
        name: 'OPPO',
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.all,
        generation: generation,
        createdAt: DateTime.utc(2026, 8, 31),
      ),
    );
  }

  Future<void> startService() async {
    service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
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
  }

  Future<CompanionClient> makeClient({int generation = 1}) async {
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: _deviceId,
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.all,
        relay: relayUri,
        generation: generation,
        hostName: 'TestHost',
      ),
      store: InMemoryCompanionStore(),
      requestTimeout: const Duration(seconds: 5),
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
        heartbeat: const Duration(milliseconds: 500),
      )..start(),
    );
    cleanups.add(client.close);
    return client;
  }

  Future<LanTransport> lanDial() async {
    final transport = LanTransport(
      host: '127.0.0.1',
      port: service.lanPortBound!,
      backoff: fastBackoff(),
    )..start();
    cleanups.add(transport.close);
    return transport;
  }

  group('over the LAN', () {
    test('connect, list, subscribe, prompt, approve — one session', () async {
      await pairDevice();
      await startService();
      final client = await makeClient();
      final events = ItemQueue<CompanionEvent>(
        client.events.where((event) => event is! HostStatusEvent),
      );
      cleanups.add(events.cancel);

      final status = await client.connect(transport: await lanDial());
      expect(status.hostName, 'TestHost');
      expect(status.versions.contains(kProtocolVersion), isTrue);

      final sessions = await client.listSessions();
      expect(sessions.single.sessionId, 's1');
      expect(sessions.single.title, 'Fix the tests');

      await client.subscribeSession('s1');
      // The subscribe answers with the initial snapshot event.
      final initial = await events.next;
      expect(initial, isA<SessionChangedEvent>());

      // Something moves on the desktop; the phone hears about it once.
      fake.sessions['s1'] = fake.sessions['s1']!.copyWith(
        attention: 'needs_approval',
      );
      await service.notifySessionsChanged();
      final changed = await events.next as SessionChangedEvent;
      expect(changed.snapshot.attention, 'needs_approval');

      await client.sendPrompt('s1', 'carry on');
      expect(fake.prompts, [(sessionId: 's1', text: 'carry on')]);

      final pressed = await client.answerApproval('s1', approve: true);
      expect(pressed, 'Yes (enter)');

      // The host stamped last-seen and kept the generation it was dialled at.
      final row = dao.getById(_deviceId.value)!;
      expect(row.lastSeenAt, isNotNull);
      expect(row.generation, 1);
    });

    test('transcript.appended follows the poll', () async {
      await pairDevice();
      await startService();
      fake.transcripts['s1'] = [
        const RemoteTranscriptMessage(role: 'user', text: 'one'),
      ];
      final client = await makeClient();
      await client.connect(transport: await lanDial());
      await client.subscribeSession('s1');
      // Reading the history is what marks the session watched — the phone's
      // own order, and what the poll sweep follows. Subscription alone keeps
      // the card live and reads nothing, so that a phone subscribed to fifty
      // sessions does not cost fifty transcript parses a tick.
      expect((await client.transcript('s1')).messages, hasLength(1));

      final events = ItemQueue<CompanionEvent>(
        client.events.where((e) => e is TranscriptAppendedEvent),
      );
      cleanups.add(events.cancel);

      fake.transcripts['s1']!.add(
        const RemoteTranscriptMessage(role: 'agent', text: 'two'),
      );
      await service.pollTranscriptsNow();

      final appended = await events.next as TranscriptAppendedEvent;
      expect([for (final m in appended.page.messages) m.text], ['two']);

      // And the history now carries both.
      final page = await client.transcript('s1');
      expect(page.messages, hasLength(2));
    });

    test('garbage on the wire refuses nothing but itself', () async {
      await pairDevice();
      await startService();

      // A stranger opens a link and talks nonsense.
      final stranger = await lanDial();
      stranger.send(Uint8List.fromList([1, 2, 3, 4]));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The real phone still gets full service.
      final client = await makeClient();
      await client.connect(transport: await lanDial());
      expect((await client.listSessions()).single.sessionId, 's1');
    });
  });

  group('over the relay', () {
    test('the client probes forward to find the host window', () async {
      await pairDevice(); // host counter: 1
      await startService();

      // The companion crashed before its last bump: its counter says 0.
      // Probing forward finds the host at 1.
      final client = await makeClient(generation: 0);
      final status = await client.connect(
        helloTimeout: const Duration(milliseconds: 900),
      );

      expect(status.hostName, 'TestHost');
      expect(client.generation, 1);
      expect((await client.listSessions()).single.sessionId, 's1');
      // The next session dials fresh: counter persisted as used + 1.
      expect(client.pairing.generation, 2);
    });

    test('a companion ahead of the host is adopted and persisted', () async {
      await pairDevice(); // host counter: 1
      await startService();

      // The host missed a bump; the companion's counter ran to 2 — inside
      // the host's listen window [1, 4).
      final client = await makeClient(generation: 2);
      await client.connect(helloTimeout: const Duration(seconds: 5));

      expect(client.generation, 2);
      expect((await client.listSessions()).single.sessionId, 's1');
      expect(
        dao.getById(_deviceId.value)!.generation,
        2,
        reason: 'the host follows the companion within the window',
      );
    });

    test('successive sessions rotate the rendezvous generation', () async {
      await pairDevice();
      await startService();

      final first = await makeClient(generation: 1);
      await first.connect(helloTimeout: const Duration(seconds: 5));
      await first.close();

      final second = await makeClient(generation: first.pairing.generation);
      await second.connect(helloTimeout: const Duration(seconds: 5));

      expect(second.generation, 2);
      expect(dao.getById(_deviceId.value)!.generation, 2);
      expect((await second.listSessions()).single.sessionId, 's1');
    });
  });

  group('revocation', () {
    test('a revoked device gets nothing, and its key is gone', () async {
      await pairDevice();
      await startService();
      final client = await makeClient();
      await client.connect(transport: await lanDial());
      expect(await client.listSessions(), isNotEmpty);

      await service.revoke(_deviceId.value);

      expect(dao.getById(_deviceId.value)!.deviceKey, isEmpty);
      expect(dao.getById(_deviceId.value)!.revoked, isTrue);

      final refused = makeClient();
      // In-flight requests from the still-open link are dropped unanswered.
      await expectLater(
        client.listSessions(),
        throwsA(isA<RemoteApiException>()),
      );
      // And a fresh connection finds nobody listening.
      final late = await refused;
      await expectLater(
        late.connect(helloTimeout: const Duration(milliseconds: 700)),
        throwsA(isA<RemoteApiException>()),
      );
    });

    test('a revoked device is not listened for after a restart', () async {
      await pairDevice();
      dao.revoke(_deviceId.value);
      await startService();

      final client = await makeClient();
      await expectLater(
        client.connect(helloTimeout: const Duration(milliseconds: 700)),
        throwsA(isA<RemoteApiException>()),
      );
    });
  });

  group('pairing through the running service', () {
    test('a phone pairs over the relay and is served immediately', () async {
      await startService();
      final session = await service.beginPairing(
        capabilities: CapabilitySet.all,
      );

      // The phone scans the QR and dials the payload's relay rendezvous.
      final store = InMemoryCompanionStore();
      final phone = CompanionPairingClient(store: store, deviceName: 'Scanner');
      final pairing = await phone.pair(session.payload);

      final paired = await session.done;
      expect(paired.name, 'Scanner');
      expect(dao.getActive(), hasLength(1));

      // The freshly paired phone connects without a restart.
      final client = CompanionClient(
        pairing: pairing,
        store: store,
        requestTimeout: const Duration(seconds: 5),
        relayFactory: (relay, rendezvous) => RelayTransport(
          endpoint: RelayTransport.endpointFor(relay, rendezvous),
          backoff: fastBackoff(),
          heartbeat: const Duration(milliseconds: 500),
        )..start(),
      );
      cleanups.add(client.close);
      await client.connect(helloTimeout: const Duration(seconds: 5));
      expect((await client.listSessions()).single.sessionId, 's1');
    });
  });
}
