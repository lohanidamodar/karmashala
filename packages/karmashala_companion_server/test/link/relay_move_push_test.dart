/// A moved pairing's pushes: the host registers the phone's token on the new
/// relay, and while that relay answers 503 (no FCM secret yet) the relay it
/// moved off carries them. A pairing that never moved is pushed as before.
library;

import 'dart:typed_data';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_store/devices.dart';
import 'package:test/test.dart';

import 'fake_bindings.dart';
import 'transport_harness.dart';

final _hostId = DeviceId.parse('11111111222222223333333344444444');
final _deviceId = 'aaaaaaaabbbbbbbbccccccccdddddddd';

void main() {
  late AppDatabase db;
  late PairedDeviceDao dao;
  late RelayServer oldRelay;
  late RelayServer newRelay;
  late Uri oldUri;
  late Uri newUri;
  late RemoteHostService service;
  late List<String> posts;
  late Set<int> unconfigured;

  setUp(() async {
    db = AppDatabase.memory();
    dao = PairedDeviceDao(db);
    posts = [];
    unconfigured = {};
    oldRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    newRelay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    oldUri = Uri.parse('http://127.0.0.1:${oldRelay.port}');
    newUri = Uri.parse('http://127.0.0.1:${newRelay.port}');
  });

  tearDown(() async {
    await service.stop();
    await oldRelay.close();
    await newRelay.close();
    db.close();
  });

  String nameOf(int port) => port == oldRelay.port ? 'old' : 'new';

  Future<void> start() async {
    service = RemoteHostService(
      devices: dao,
      hostId: _hostId,
      bindings: FakeRemoteBindings().bindings,
      relay: newUri,
      knownRelays: KnownRelays(current: newUri, retired: [oldUri]),
      lanPort: 0,
      advertise: false,
      transcriptPollInterval: Duration.zero,
      relayFactory: (relay, rendezvous) => RelayTransport(
        endpoint: RelayTransport.endpointFor(relay, rendezvous),
        backoff: fastBackoff(),
      )..start(),
      pushPost: (url, body) async {
        final register = url.path.endsWith('/register');
        posts.add('${nameOf(url.port)} ${register ? 'register' : 'push'}');
        if (unconfigured.contains(url.port)) {
          return (status: 503, body: 'push is not configured\n');
        }
        return register ? (status: 204, body: '') : (status: 202, body: '');
      },
    );
    await service.start();
  }

  void pair({required String relayUrl}) => dao
    ..insert(
      PairedDevice(
        id: _deviceId,
        name: 'pixel',
        deviceKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
        capabilities: CapabilitySet.all,
        generation: 1,
        createdAt: DateTime.utc(2026, 10, 6),
        relayUrl: relayUrl,
      ),
    )
    ..updatePush(_deviceId, token: 'fcm-token', platform: 'android');

  Future<void> news() => service.pushAttentionNews(
    sessionId: 's1',
    title: 'Done',
    kind: 'finished',
  );

  test('after a move the token is registered on the new relay, and the push '
      'goes there', () async {
    pair(relayUrl: oldUri.toString());
    dao.moveRelay(_deviceId, newUri.toString());
    await start();

    await news();

    expect(posts, ['new register', 'new push']);
  });

  test('the new relay answering 503: the old relay carries the push, and the '
      'new one is not asked again on the next', () async {
    pair(relayUrl: oldUri.toString());
    dao
      ..moveRelay(_deviceId, newUri.toString())
      ..settleRelayMove(_deviceId);
    unconfigured.add(newRelay.port);
    await start();

    await news();
    await news();

    expect(posts, ['new register', 'old register', 'old push', 'old push']);
  });

  test('a pairing made on the new relay falls back to the retired one while '
      'the new one has no push', () async {
    pair(relayUrl: newUri.toString());
    unconfigured.add(newRelay.port);
    await start();

    await news();

    expect(posts, ['new register', 'old register', 'old push']);
  });

  test('a pairing that never moved is pushed on its own relay alone', () async {
    pair(relayUrl: oldUri.toString());
    await start();

    await news();

    expect(posts, ['old register', 'old push']);
  });
}
