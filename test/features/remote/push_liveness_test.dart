/// The service half of push routing, over a real in-process relay: a phone
/// with a live link is never pushed; a phone that left is.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/remote/application/remote_host_service.dart';
import 'package:karmashala_remote/client.dart';
import 'package:karmashala/src/features/remote/data/paired_device_dao.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/push.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = DeviceId.parse('aaaaaaaabbbbbbbbccccccccdddddddd');
final _secret = Uint8List.fromList(List<int>.generate(32, (i) => 0x51 + i));

Future<void> _eventually(
  bool Function() condition, {
  String reason = 'condition never held',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late FakeRemoteBindings fake;
  late RelayServer relay;
  late Uri relayUri;
  late RemoteHostService service;
  late List<({Uri url, String raw})> posts;
  final cleanups = <Future<void> Function()>[];

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    fake = FakeRemoteBindings()..addSession('s1');
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    relayUri = Uri.parse('http://127.0.0.1:${relay.port}');
    posts = [];
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

  Future<void> pairDevice({String? pushToken = 'fcm-oppo-1'}) async {
    dao.insert(
      PairedDevice(
        id: _deviceId.value,
        name: 'OPPO',
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.all,
        generation: kFirstSessionGeneration,
        createdAt: DateTime.utc(2026, 8, 31),
        pushToken: pushToken,
        pushPlatform: pushToken == null ? null : 'android',
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
      pushPost: (url, jsonBody) async {
        posts.add((url: url, raw: jsonBody));
        return url.path.endsWith('/register')
            ? (status: 204, body: '')
            : (status: 202, body: 'accepted\n');
      },
    );
    await service.start();
  }

  Future<CompanionClient> makeClient() async {
    final client = CompanionClient(
      pairing: CompanionPairing(
        hostId: _hostId,
        deviceId: _deviceId,
        deviceKey: await deviceKey(),
        capabilities: CapabilitySet.all,
        relay: relayUri,
        generation: 1,
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
    return client;
  }

  Future<void> news({String kind = 'needs_approval'}) => service
      .pushAttentionNews(sessionId: 's1', title: 'Fix the tests', kind: kind);

  test(
    'before any connection the link is not live, so news is pushed',
    () async {
      await pairDevice();
      await startService();

      expect(service.hasLiveLink(_deviceId.value), isFalse);
      await news(kind: 'finished');

      expect(
        [for (final p in posts) p.url.path],
        ['/v1/push/register', '/v1/push'],
      );
      final body = jsonDecode(posts[1].raw) as Map<String, Object?>;
      final opened = await openPushPayload(
        deviceKey: SecretKeyData(await deviceKey()),
        sealed: base64Url.decode(body['payload']! as String),
      );
      expect(opened['sessionId'], 's1');
      expect(opened['title'], 'Fix the tests');
      expect(opened['kind'], 'finished');
      // The relay saw ciphertext and an opaque tag, nothing else.
      expect(posts[1].raw, isNot(contains('Fix the tests')));
      expect(posts[1].raw, isNot(contains(_deviceId.value)));
    },
  );

  test(
    'a connected phone is never pushed — it hears session.changed',
    () async {
      await pairDevice();
      await startService();
      final client = await makeClient();
      cleanups.add(client.close);
      await client.connect(helloTimeout: const Duration(seconds: 5));

      await _eventually(
        () => service.hasLiveLink(_deviceId.value),
        reason: 'the hello never marked the link live',
      );
      await news();

      expect(posts, isEmpty);
    },
  );

  test('a phone that left starts getting pushes again', () async {
    await pairDevice();
    await startService();
    final client = await makeClient();
    await client.connect(helloTimeout: const Duration(seconds: 5));
    await _eventually(() => service.hasLiveLink(_deviceId.value));

    await client.close();
    await _eventually(
      () => !service.hasLiveLink(_deviceId.value),
      reason: 'the drop never cleared the live link',
    );
    await news();

    expect(
      [for (final p in posts) p.url.path],
      ['/v1/push/register', '/v1/push'],
    );
  });

  test('no stored token means silence, not an error', () async {
    await pairDevice(pushToken: null);
    await startService();

    await news();

    expect(posts, isEmpty);
  });
}
