/// The push routing matrix, over a recorded poster: who gets a push, what
/// the relay sees (opaque bytes only), and how failures drop.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:chitragupta/src/features/remote/domain/paired_device.dart';
import 'package:chitragupta/src/features/remote/protocol.dart';
import 'package:chitragupta/src/features/remote/push/push_crypto.dart';
import 'package:chitragupta/src/features/remote/push/push_fanout.dart';
import 'package:chitragupta/src/features/remote/push/relay_push_client.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

const _deviceId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

final Uint8List _key = Uint8List.fromList(List.generate(32, (i) => i));

PairedDevice _device({
  String id = _deviceId,
  CapabilitySet? capabilities,
  String? token = 'fcm-token-1',
  String? platform = 'android',
  bool revoked = false,
  Uint8List? key,
}) => PairedDevice(
  id: id,
  name: 'OPPO',
  deviceKey: key ?? (revoked ? Uint8List(0) : _key),
  capabilities: capabilities ?? CapabilitySet.all,
  generation: 1,
  createdAt: DateTime.utc(2026, 8, 31),
  revoked: revoked,
  pushToken: token,
  pushPlatform: platform,
);

/// Records every post; scripts answers per call when [handler] is set.
class RecordingPost {
  final posts = <({Uri url, Map<String, Object?> body, String raw})>[];
  Future<({int status, String body})> Function(
    Uri url,
    Map<String, Object?> body,
  )?
  handler;

  Future<({int status, String body})> call(Uri url, String jsonBody) async {
    final body = jsonDecode(jsonBody) as Map<String, Object?>;
    posts.add((url: url, body: body, raw: jsonBody));
    final scripted = handler;
    if (scripted != null) return scripted(url, body);
    return url.path.endsWith('/register')
        ? (status: 204, body: '')
        : (status: 202, body: 'accepted\n');
  }

  List<String> get paths => [for (final post in posts) post.url.path];
}

void main() {
  late RecordingPost post;
  late List<PairedDevice> devices;
  late Set<String> live;
  late List<String> log;
  late PushFanout fanout;

  setUp(() {
    post = RecordingPost();
    devices = [_device()];
    live = {};
    log = [];
    fanout = PushFanout(
      devices: () => devices,
      hasLiveLink: live.contains,
      // Loop 80: one client per device's own relay. These devices all sit on
      // the same one; `clientFor` answering null is the relay-off case.
      clientFor: (device) => RelayPushClient(
        relay: Uri.parse('wss://relay.example.com'),
        post: post.call,
      ),
      now: () => DateTime.utc(2026, 8, 31, 12),
      onLog: log.add,
    );
  });

  Future<void> notify({String kind = 'needs_approval'}) => fanout
      .notifyAttention(sessionId: 's1', title: 'Fix the tests', kind: kind);

  group('an eligible offline device', () {
    test('registers its token, then gets a sealed payload', () async {
      await notify(kind: 'finished');

      expect(post.paths, ['/v1/push/register', '/v1/push']);
      final register = post.posts[0].body;
      expect(register['token'], 'fcm-token-1');
      expect(register['platform'], 'android');
      final tag = register['tag'] as String;
      expect(tag, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(tag, isNot(_deviceId), reason: 'the tag is never a device id');
      expect(post.posts[1].body['tag'], tag);

      final opened = await openPushPayload(
        deviceKey: SecretKeyData(_key),
        sealed: base64Url.decode(post.posts[1].body['payload']! as String),
      );
      expect(opened['sessionId'], 's1');
      expect(opened['title'], 'Fix the tests');
      expect(opened['kind'], 'finished');
    });

    test('nothing readable crosses the wire', () async {
      await notify();

      for (final sent in post.posts) {
        expect(sent.raw, isNot(contains('Fix the tests')));
        expect(sent.raw, isNot(contains('s1"')));
        expect(sent.raw, isNot(contains('needs_approval')));
        expect(sent.raw, isNot(contains(_deviceId)));
      }
    });

    test('registers once, then only pushes', () async {
      await notify();
      await notify();

      expect(post.paths, ['/v1/push/register', '/v1/push', '/v1/push']);
    });

    test('a rotated token re-registers before the next push', () async {
      await notify();
      devices = [_device(token: 'fcm-token-2')];

      await notify();

      expect(post.paths, [
        '/v1/push/register',
        '/v1/push',
        '/v1/push/register',
        '/v1/push',
      ]);
      expect(post.posts[2].body['token'], 'fcm-token-2');
    });
  });

  group('the routing matrix', () {
    test('a live link means no push — session.changed carries it', () async {
      live.add(_deviceId);

      await notify();

      expect(post.posts, isEmpty);
    });

    test('no stored token, no push', () async {
      devices = [_device(token: null)];

      await notify();

      expect(post.posts, isEmpty);
    });

    test('no receive_notifications grant, no push', () async {
      devices = [
        _device(
          capabilities: CapabilitySet.of(
            Capability.values.where(
              (c) => c != Capability.receiveNotifications,
            ),
          ),
        ),
      ];

      await notify();

      expect(post.posts, isEmpty);
    });

    test('a revoked device is never sealed for', () async {
      devices = [_device(revoked: true)];

      await notify();

      expect(post.posts, isEmpty);
    });

    test('only the eligible devices of a mixed fleet are pushed', () async {
      devices = [
        _device(),
        _device(id: 'b' * 32, token: null),
        _device(id: 'c' * 32, key: Uint8List.fromList(List.filled(32, 7))),
      ];
      live.add('c' * 32);

      await notify();

      expect(post.paths, ['/v1/push/register', '/v1/push']);
    });
  });

  group('failure handling — always logged-and-dropped', () {
    test(
      'a relay restart (unknown tag) re-registers and retries once',
      () async {
        var pushes = 0;
        post.handler = (url, body) async {
          if (url.path.endsWith('/register')) return (status: 204, body: '');
          pushes++;
          return pushes == 1
              ? (status: 404, body: 'unknown tag\n')
              : (status: 202, body: 'accepted\n');
        };

        await notify();

        expect(post.paths, [
          '/v1/push/register',
          '/v1/push',
          '/v1/push/register',
          '/v1/push',
        ]);
      },
    );

    test('a gone token clears the registration for a fresh one', () async {
      post.handler = (url, body) async => url.path.endsWith('/register')
          ? (status: 204, body: '')
          : (status: 410, body: 'token gone\n');

      await notify();
      await notify();

      // Re-registered each time: the cached registration was dropped.
      expect(post.paths, [
        '/v1/push/register',
        '/v1/push',
        '/v1/push/register',
        '/v1/push',
      ]);
    });

    test('an unconfigured relay is logged, never thrown', () async {
      post.handler = (url, body) async => url.path.endsWith('/register')
          ? (status: 204, body: '')
          : (status: 503, body: 'push delivery not configured\n');

      await notify();

      expect(log, contains('a push was not delivered: notConfigured'));
    });

    test('a poster that throws never crashes the fan-out', () async {
      post.handler = (url, body) async =>
          throw Exception('network unreachable');

      await notify();

      expect(log.single, startsWith('push to a device failed'));
      expect(log.single, isNot(contains('Fix the tests')));
    });
  });

  group('endpoint mapping', () {
    test('keeps a self-hoster\'s port and path prefix', () {
      expect(
        RelayPushClient.endpointFor(
          Uri.parse('wss://relay.example.com'),
          'v1/push',
        ),
        Uri.parse('https://relay.example.com/v1/push'),
      );
      expect(
        RelayPushClient.endpointFor(
          Uri.parse('http://127.0.0.1:8787/base/'),
          'v1/push/register',
        ),
        Uri.parse('http://127.0.0.1:8787/base/v1/push/register'),
      );
    });
  });

  group('per-device relays (loop 80)', () {
    test('each push goes to the device\'s OWN relay', () async {
      final local = _device(id: _deviceId, token: 'token-local');
      final hosted = _device(
        id: 'b' * 32,
        token: 'token-hosted',
        key: Uint8List.fromList(List<int>.generate(32, (i) => 200 - i)),
      );
      devices = [local, hosted];
      fanout = PushFanout(
        devices: () => devices,
        hasLiveLink: live.contains,
        clientFor: (device) => RelayPushClient(
          relay: device.id == local.id
              ? Uri.parse('ws://192.168.1.7:8787')
              : Uri.parse('wss://relay.example.com'),
          post: post.call,
        ),
        now: () => DateTime.utc(2026, 8, 31, 12),
        onLog: log.add,
      );

      await notify();

      final hosts = {for (final p in post.posts) p.url.host};
      expect(hosts, {'192.168.1.7', 'relay.example.com'});
    });

    test('a device whose relay is off gets nothing, and says why', () async {
      fanout = PushFanout(
        devices: () => devices,
        hasLiveLink: live.contains,
        // Null is the relay-switched-off answer: a push through it could not
        // arrive, and posting to the other relay would leak the news to a
        // server this phone never agreed to.
        clientFor: (device) => null,
        now: () => DateTime.utc(2026, 8, 31, 12),
        onLog: log.add,
      );

      await notify();

      expect(post.posts, isEmpty);
      expect(log, contains('a push was not sent: that relay is off'));
    });
  });
}
