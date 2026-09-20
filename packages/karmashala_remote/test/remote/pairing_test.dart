/// Pairing, host and phone together, over a real loopback LAN link: the QR
/// payload round-trips, both ends derive the same key, the confirm round-trip
/// gates persistence, the secret is single-use and the code expires.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:test/test.dart';

import './transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');

PairingPayload payload({CapabilitySet? capabilities}) =>
    PairingPayload.generate(
      relay: Uri.parse('wss://relay.example.com'),
      hostId: _hostId,
      capabilities: capabilities ?? CapabilitySet.all,
    );

void main() {
  group('the QR payload', () {
    test('round-trips through its QR string', () {
      final original = payload();
      final decoded = PairingPayload.decode(original.encode());

      expect(decoded.relay, original.relay);
      expect(decoded.rendezvous, original.rendezvous);
      expect(decoded.version, kProtocolVersion);
      expect(decoded.secret, original.secret);
      expect(decoded.hostId, _hostId);
      expect(decoded.capabilities, CapabilitySet.all);
    });

    test('refuses junk', () {
      expect(
        () => PairingPayload.decode('not json'),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => PairingPayload.decode('{"relay": 1}'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('a relay that is not a URL is refused, not a FormatException', () {
      final json = jsonDecode(payload().encode()) as Map<String, Object?>;
      json['relay'] = 'http://[::1';
      expect(
        () => PairingPayload.decode(jsonEncode(json)),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('the host session on its own', () {
    test('expires on its own clock, with no frame to prompt it', () async {
      final session = HostPairingSession(
        payload: payload(),
        hostName: 'Desk',
        persist: (_) async {},
        ttl: const Duration(milliseconds: 50),
      )..attach(_DeadTransport());
      await expectLater(
        session.done.timeout(const Duration(seconds: 5)),
        throwsA(isA<PairingException>()),
      );
    });

    test('a link whose send throws does not poison the frame chain', () async {
      // The first throw used to leave every later frame, from either leg,
      // unanswered. Here the dead leg is handed a hello, then the same phone
      // pairs over a live one.
      final server = await LanTransportServer.bind(
        address: '127.0.0.1',
        port: 0,
      );
      addTearDown(server.close);
      final shown = payload();
      final persisted = <PairedDevice>[];
      final session = HostPairingSession(
        payload: shown,
        hostName: 'Desk',
        persist: (device) async => persisted.add(device),
      );
      final client = CompanionPairingClient(
        store: InMemoryCompanionStore(),
        deviceName: 'OPPO',
      );
      final dead = _DeadTransport();
      session.handleFrame(
        dead,
        PairHello(deviceId: client.deviceId, name: 'OPPO').encode(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dead.sends, 1);

      final links = ItemQueue<LanLink>(server.connections);
      final phone = LanTransport(
        host: '127.0.0.1',
        port: server.port,
        backoff: fastBackoff(),
      )..start();
      addTearDown(phone.close);
      session.attach(await links.next);
      await links.cancel();

      await client.pair(
        shown,
        transport: phone,
        timeout: const Duration(seconds: 10),
      );
      expect(persisted, hasLength(1));
    });
  });

  group('host and phone over a loopback link', () {
    late LanTransportServer server;
    late LanTransport phoneTransport;

    setUp(() async {
      server = await LanTransportServer.bind(address: '127.0.0.1', port: 0);
    });

    tearDown(() async {
      await phoneTransport.close();
      await server.close();
    });

    Future<(HostPairingSession, CompanionPairingClient, List<PairedDevice>)>
    fixture(
      PairingPayload shown, {
      DateTime Function()? now,
      Future<void> Function(PairedDevice device)? persist,
    }) async {
      final persisted = <PairedDevice>[];
      final session = HostPairingSession(
        payload: shown,
        hostName: 'Desk',
        persist: persist ?? (device) async => persisted.add(device),
        now: now,
      );
      final links = ItemQueue<LanLink>(server.connections);
      phoneTransport = LanTransport(
        host: '127.0.0.1',
        port: server.port,
        backoff: fastBackoff(),
      )..start();
      session.attach(await links.next);
      await links.cancel();
      final client = CompanionPairingClient(
        store: InMemoryCompanionStore(),
        deviceName: 'OPPO',
      );
      return (session, client, persisted);
    }

    test('the full round-trip pairs both ends on the same key', () async {
      final shown = payload();
      final (session, client, persisted) = await fixture(shown);

      final pairing = await client.pair(
        shown,
        transport: phoneTransport,
        timeout: const Duration(seconds: 10),
      );
      final device = await session.done;

      expect(device.id, client.deviceId.value);
      expect(device.name, 'OPPO');
      expect(persisted, [device]);
      expect(
        pairing.deviceKey,
        device.deviceKey,
        reason: 'both ends must hold the same derived key',
      );
      expect(pairing.hostId, _hostId);
      expect(pairing.hostName, 'Desk');
      expect(pairing.capabilities, CapabilitySet.all);
      expect(device.capabilities, CapabilitySet.all);
      expect(
        device.generation,
        kFirstSessionGeneration,
        reason: 'pairing spent generation 0; sessions start at 1',
      );
      expect(pairing.generation, kFirstSessionGeneration);

      // And the pairing reached the phone's store.
      final stored = await CompanionPairing.load(client.store);
      expect(stored!.deviceKey, pairing.deviceKey);
    });

    test('a narrower grant is carried into both records', () async {
      final shown = payload(
        capabilities: CapabilitySet.of(const [
          Capability.viewSessions,
          Capability.readTranscript,
        ]),
      );
      final (session, client, _) = await fixture(shown);

      final pairing = await client.pair(shown, transport: phoneTransport);
      final device = await session.done;

      expect(device.capabilities.has(Capability.sendPrompt), isFalse);
      expect(pairing.capabilities.has(Capability.sendPrompt), isFalse);
      expect(pairing.capabilities.has(Capability.viewSessions), isTrue);
    });

    test('an expired code pairs nobody', () async {
      final shown = payload();
      var now = DateTime.utc(2026, 8, 31, 12);
      final (session, client, persisted) = await fixture(shown, now: () => now);
      now = now.add(kPairingTtl + const Duration(seconds: 1));

      await expectLater(
        client.pair(
          shown,
          transport: phoneTransport,
          timeout: const Duration(milliseconds: 600),
        ),
        throwsA(isA<CompanionPairingException>()),
      );
      expect(persisted, isEmpty);
      await expectLater(session.done, throwsA(isA<PairingException>()));
    });

    test(
      'a store that refuses the device fails the session out loud',
      () async {
        // A throw from persist used to poison the frame chain and leave the
        // dialog waiting for a device that would never be reported.
        final shown = payload();
        final (session, client, persisted) = await fixture(
          shown,
          persist: (_) async => throw StateError('disk full'),
        );

        await expectLater(
          client.pair(
            shown,
            transport: phoneTransport,
            timeout: const Duration(milliseconds: 800),
          ),
          throwsA(isA<CompanionPairingException>()),
        );
        await expectLater(
          session.done,
          throwsA(
            isA<PairingException>().having(
              (e) => e.message,
              'message',
              contains('disk full'),
            ),
          ),
        );
        expect(persisted, isEmpty);
      },
    );

    test('a wrong secret cannot complete the round-trip', () async {
      final shown = payload();
      final (session, client, persisted) = await fixture(shown);

      // The phone scanned a forged payload: same rendezvous, wrong secret.
      final forged = PairingPayload(
        relay: shown.relay,
        rendezvous: shown.rendezvous,
        secret: Uint8List(32),
        hostId: shown.hostId,
        capabilities: shown.capabilities,
      );

      await expectLater(
        client.pair(
          forged,
          transport: phoneTransport,
          timeout: const Duration(milliseconds: 800),
        ),
        throwsA(isA<CompanionPairingException>()),
      );
      expect(
        persisted,
        isEmpty,
        reason: 'nothing is stored until the sealed ack proves the key',
      );
      await session.close();
    });

    test('the secret is single-use: a second phone is ignored', () async {
      final shown = payload();
      final (session, client, persisted) = await fixture(shown);

      await client.pair(shown, transport: phoneTransport);
      await session.done;

      // A second phone dials the same rendezvous with the real secret.
      final second = CompanionPairingClient(
        store: InMemoryCompanionStore(),
        deviceName: 'Intruder',
      );
      final secondTransport = LanTransport(
        host: '127.0.0.1',
        port: server.port,
        backoff: fastBackoff(),
      )..start();
      addTearDown(secondTransport.close);

      await expectLater(
        second.pair(
          shown,
          transport: secondTransport,
          timeout: const Duration(milliseconds: 800),
        ),
        throwsA(isA<CompanionPairingException>()),
      );
      expect(persisted, hasLength(1));
    });
  });

  group('the wire vocabulary', () {
    test('hellos round-trip and junk decodes to null', () {
      final rendezvous = payload().rendezvous;
      expect(
        LinkHello.tryDecode(LinkHello(rendezvous).encode())!.rendezvous,
        rendezvous,
      );
      final hello = PairHello(deviceId: DeviceId.parse('c' * 32), name: 'OPPO');
      final decoded = PairHello.tryDecode(hello.encode())!;
      expect(decoded.deviceId.value, 'c' * 32);
      expect(decoded.name, 'OPPO');

      expect(LinkHello.tryDecode(<int>[1, 2, 3]), isNull);
      expect(PairHello.tryDecode(LinkHello(rendezvous).encode()), isNull);
      expect(LinkHello.tryDecode(List.filled(5000, 0x20)), isNull);
    });
  });
}

/// A link whose far end is already gone: every send throws.
class _DeadTransport extends RemoteTransport {
  int sends = 0;

  @override
  Stream<Uint8List> get frames => const Stream<Uint8List>.empty();

  @override
  Stream<TransportState> get states =>
      Stream<TransportState>.value(TransportState.closed);

  @override
  TransportState get state => TransportState.closed;

  @override
  void send(List<int> frame) {
    sends++;
    throw const TransportException('transport is closed');
  }

  @override
  Future<void> close() async {}
}
