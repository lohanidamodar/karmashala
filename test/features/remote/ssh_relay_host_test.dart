/// A relay on the user's own box, served through beside the hosted one: real
/// sockets on 127.0.0.1, and a relay that answers only under its access token.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _phone = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));
const _token = '0123456789abcdef0123456789abcdef';

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer hostedRelay;
  late RelayServer boxRelay;
  late Uri hostedUri;
  late Uri boxUri;
  late RemoteHostService service;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    hostedRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    boxRelay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: const RelayOptions(accessToken: _token),
    );
    hostedUri = Uri.parse('http://127.0.0.1:${hostedRelay.port}');
    boxUri = Uri.parse('ws://127.0.0.1:${boxRelay.port}/k/$_token');
  });

  tearDown(() async {
    for (final cleanup in cleanups.reversed.toList()) {
      await cleanup();
    }
    cleanups.clear();
    await service.stop();
    await hostedRelay.close();
    await boxRelay.close();
    db.close();
  });

  Future<Uint8List> key() async => Uint8List.fromList(
    (await deriveDeviceKey(
      pairingSecret: _secret,
      hostId: _hostId,
      deviceId: _phone,
    )).bytes,
  );

  Future<void> pair({required String relayUrl}) async => dao.insert(
    PairedDevice(
      id: _phone.value,
      name: 'phone',
      deviceKey: await key(),
      capabilities: CapabilitySet.all,
      generation: kFirstSessionGeneration,
      createdAt: DateTime.utc(2026, 9, 17),
      relayUrl: relayUrl,
    ),
  );

  RemoteTransport dial(Uri relay, RendezvousId rendezvous) => RelayTransport(
    endpoint: RelayTransport.endpointFor(relay, rendezvous),
    backoff: fastBackoff(),
    heartbeat: const Duration(milliseconds: 500),
  )..start();

  Future<void> startService({
    List<Uri> extraRelays = const [],
    bool hostedEnabled = true,
  }) async {
    service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: fake.bindings,
      relay: hostedUri,
      hostedEnabled: hostedEnabled,
      extraRelays: extraRelays,
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: dial,
    );
    await service.start();
  }

  Future<CompanionClient> phoneOn(Uri relay) async {
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: _phone,
        deviceKey: await key(),
        capabilities: CapabilitySet.all,
        relay: relay,
        generation: dao.getById(_phone.value)!.generation,
        hostName: 'TestHost',
      ),
      store: InMemoryCompanionStore(),
      requestTimeout: const Duration(seconds: 5),
      relayFactory: dial,
    );
    cleanups.add(client.close);
    return client;
  }

  test('a phone paired through the hosted relay is met at the box too, and '
      'is told about it', () async {
    await pair(relayUrl: hostedUri.toString());
    await startService(extraRelays: [boxUri]);

    final client = await phoneOn(boxUri);
    final status = await client.connect();

    // No re-pair: the rendezvous comes from the device key, not the URL, and
    // the announcement is how the phone's saved relays heal.
    expect(status.relays.map((url) => '$url'), contains('$boxUri'));
    expect(status.relays.map((url) => '$url'), contains('$hostedUri'));
    expect((await client.listSessions()).single.sessionId, 's1');
  });

  test(
    'a box added while remote access runs is served without a restart',
    () async {
      await pair(relayUrl: hostedUri.toString());
      await startService();
      expect(service.activeRelayUrlsFor(dao.getById(_phone.value)!), [
        hostedUri,
      ]);

      await service.updateRelays(
        localRelayUrl: null,
        hostedEnabled: true,
        extraRelays: [boxUri],
      );

      final client = await phoneOn(boxUri);
      await client.connect();
      expect((await client.listSessions()).single.sessionId, 's1');
    },
  );

  test(
    'the box stays a meeting place with the hosted relay switched off',
    () async {
      await pair(relayUrl: boxUri.toString());
      await startService(extraRelays: [boxUri], hostedEnabled: false);

      final device = dao.getById(_phone.value)!;
      expect(service.activeRelayUrlsFor(device), [boxUri]);
      final client = await phoneOn(boxUri);
      await client.connect();
      expect((await client.listSessions()).single.sessionId, 's1');
    },
  );

  test('a push never goes to the box: it holds no FCM credentials', () async {
    await pair(relayUrl: boxUri.toString());
    await startService(extraRelays: [boxUri]);
    final device = dao.getById(_phone.value)!;

    // The push is this desktop's POST, so the hosted relay can carry it…
    expect(service.relayUrlFor(device), hostedUri);

    // …and with that off there is nowhere that could deliver one.
    await service.updateRelays(
      localRelayUrl: null,
      hostedEnabled: false,
      extraRelays: [boxUri],
    );
    expect(service.relayUrlFor(device), isNull);
  });

  test(
    'a new pairing names the box among the relays the phone may use',
    () async {
      await startService(extraRelays: [boxUri]);

      final session = await service.beginPairing(
        capabilities: CapabilitySet.all,
        relay: boxUri,
      );
      cleanups.add(service.cancelPairing);

      expect(session.payload.relay, boxUri);
      expect(
        session.payload.relays.map((url) => '$url'),
        containsAll(['$boxUri', '$hostedUri']),
      );
    },
  );

  test('the box answers nobody who does not hold its token', () async {
    await pair(relayUrl: hostedUri.toString());
    await startService(extraRelays: [boxUri]);

    final stranger = await phoneOn(
      Uri.parse('ws://127.0.0.1:${boxRelay.port}'),
    );
    await expectLater(
      stranger.connect(helloTimeout: const Duration(seconds: 1)),
      throwsA(anything),
    );
  });
}
