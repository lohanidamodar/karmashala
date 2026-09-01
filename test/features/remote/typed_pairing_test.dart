/// The typed-code pairing path, host and phone together over a real loopback
/// link: the phone holds only the 20-byte code secret, derives everything,
/// says `needHost` in its hello, reads the host's identity and grant out of a
/// confirm sealed by the secret alone, and proves the id-bound device key with
/// the ack/done round-trip before anything is persisted.
library;

import 'dart:typed_data';

import 'package:karmashala/src/features/remote/client/companion_pairing_client.dart';
import 'package:karmashala/src/features/remote/client/companion_store.dart';
import 'package:karmashala/src/features/remote/domain/paired_device.dart';
import 'package:karmashala/src/features/remote/pairing/host_pairing.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_payload.dart';
import 'package:karmashala/src/features/remote/pairing/pairing_wire.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:karmashala/src/features/remote/transport/lan_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _relay = Uri.parse('wss://relay.example.com');

void main() {
  late LanTransportServer server;
  late LanTransport phoneTransport;

  setUp(() async {
    server = await LanTransportServer.bind(address: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    await phoneTransport.close();
    await server.close();
  });

  Future<
    (
      PairingPayload,
      HostPairingSession,
      CompanionPairingClient,
      List<PairedDevice>,
    )
  >
  fixture({CapabilitySet? capabilities}) async {
    final shown = await PairingPayload.generateWithCode(
      relay: _relay,
      hostId: _hostId,
      capabilities: capabilities ?? CapabilitySet.all,
    );
    final persisted = <PairedDevice>[];
    final session = HostPairingSession(
      payload: shown,
      hostName: 'Desk',
      persist: (device) async => persisted.add(device),
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
    return (shown, session, client, persisted);
  }

  test('the typed code alone pairs both ends on the same key, and the '
      'confirm delivers identity and grant', () async {
    final (shown, session, client, persisted) = await fixture(
      capabilities: CapabilitySet.of(const [
        Capability.viewSessions,
        Capability.approve,
      ]),
    );
    String? confirmedHost;
    CapabilitySet? confirmedGrant;

    final pairing = await client.pairWithTypedCode(
      codeSecret: shown.typedSecret!,
      relay: _relay,
      transport: phoneTransport,
      timeout: const Duration(seconds: 10),
      onConfirm: (host, grant) {
        confirmedHost = host;
        confirmedGrant = grant;
      },
    );
    final device = await session.done;

    expect(pairing.hostId, _hostId, reason: 'learned from the sealed confirm');
    expect(pairing.hostName, 'Desk');
    expect(pairing.relay, _relay, reason: "the phone's own configured relay");
    expect(pairing.capabilities.has(Capability.approve), isTrue);
    expect(pairing.capabilities.has(Capability.sendPrompt), isFalse);
    expect(confirmedHost, 'Desk');
    expect(confirmedGrant?.has(Capability.approve), isTrue);
    expect(
      pairing.deviceKey,
      device.deviceKey,
      reason: 'both ends must derive the same id-bound key',
    );
    expect(pairing.generation, kFirstSessionGeneration);
    expect(persisted, [device]);
    expect(
      (await CompanionPairing.load(client.store))!.deviceKey,
      pairing.deviceKey,
    );
  });

  test('the QR path still redeems a payload generated with a code — one '
      'session serves both', () async {
    final (shown, session, client, persisted) = await fixture();

    final pairing = await client.pair(shown, transport: phoneTransport);
    final device = await session.done;

    expect(pairing.deviceKey, device.deviceKey);
    expect(persisted, hasLength(1));
  });

  test('a mistyped code derives the wrong keys and pairs nobody', () async {
    final (shown, session, client, persisted) = await fixture();
    final wrong = Uint8List.fromList(shown.typedSecret!);
    wrong[0] ^= 0x01;

    await expectLater(
      client.pairWithTypedCode(
        codeSecret: wrong,
        relay: _relay,
        transport: phoneTransport,
        timeout: const Duration(milliseconds: 800),
      ),
      throwsA(isA<CompanionPairingException>()),
    );
    expect(persisted, isEmpty);
    await session.close();
  });

  test('a confirm without a host id (an old desktop) is refused in words, '
      'not mis-parsed', () async {
    final (shown, session, client, persisted) = await fixture();
    // An old host would never send the confirm on the secret-only channel at
    // all, so the phone times out; the message must say what to do instead.
    await session.close();

    await expectLater(
      client.pairWithTypedCode(
        codeSecret: shown.typedSecret!,
        relay: _relay,
        transport: phoneTransport,
        timeout: const Duration(milliseconds: 600),
      ),
      throwsA(
        isA<CompanionPairingException>().having(
          (e) => e.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
    expect(persisted, isEmpty);
  });

  test('the needHost hello round-trips on the wire and stays absent for the '
      'QR path', () {
    final asking = PairHello(
      deviceId: DeviceId.parse('c' * 32),
      name: 'OPPO',
      needsHostIdentity: true,
    );
    expect(PairHello.tryDecode(asking.encode())!.needsHostIdentity, isTrue);

    final plain = PairHello(deviceId: DeviceId.parse('c' * 32), name: 'OPPO');
    expect(
      String.fromCharCodes(plain.encode()).contains('needHost'),
      isFalse,
      reason: 'QR-path bytes must stay exactly as before',
    );
    expect(PairHello.tryDecode(plain.encode())!.needsHostIdentity, isFalse);

    final confirm = PairingMessage.decode(
      PairingMessage.encodeConfirm(
        hostName: 'Desk',
        capabilities: CapabilitySet.all,
        hostId: _hostId,
      ),
    )!;
    expect(confirm['hostId'], _hostId.value);
    final withoutId = PairingMessage.decode(
      PairingMessage.encodeConfirm(
        hostName: 'Desk',
        capabilities: CapabilitySet.all,
      ),
    )!;
    expect(withoutId.containsKey('hostId'), isFalse);
  });
}
