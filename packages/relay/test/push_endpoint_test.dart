import 'dart:convert';
import 'dart:io';

import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:test/test.dart';

const _tag = 'abcdefabcdefabcdefabcdefabcdefab';
const _otherTag = '00112233445566778899aabbccddeeff';

late RelayServer relay;

Future<void> _start({RelayOptions options = const RelayOptions()}) async {
  relay = await RelayServer.bind(
    address: '127.0.0.1',
    port: 0,
    options: options,
  );
}

Future<(int, String)> _post(String path, Object? body) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${relay.port}$path'),
    );
    request.headers.contentType = ContentType.json;
    request.write(body is String ? body : jsonEncode(body));
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}

Future<String> _get(String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${relay.port}$path'),
    );
    final response = await request.close();
    return '${response.statusCode} '
        '${await response.transform(utf8.decoder).join()}';
  } finally {
    client.close(force: true);
  }
}

Future<(int, String)> _register({
  String tag = _tag,
  String token = 'fcm-token-1',
  String platform = 'android',
}) => _post('/v1/push/register', {
  'tag': tag,
  'token': token,
  'platform': platform,
});

/// The test-side implementation of the delivery boundary.
class FakeDelivery implements PushDelivery {
  final delivered = <({String token, String platform, String payload})>[];
  Exception? failure;

  @override
  Future<void> deliver({
    required String token,
    required String platform,
    required String payload,
  }) async {
    final refusal = failure;
    if (refusal != null) throw refusal;
    delivered.add((token: token, platform: platform, payload: payload));
  }
}

void main() {
  tearDown(() async => relay.close());

  group('registering a token', () {
    setUp(_start);

    test('stores it under the opaque tag', () async {
      final (status, _) = await _register();

      expect(status, 204);
      expect(relay.pushTokenCount, 1);
      expect(await _get('/healthz'), contains('"push_tokens":1'));
    });

    test('re-registering the same tag replaces the token', () async {
      await _register(token: 'old');
      final (status, _) = await _register(token: 'new');

      expect(status, 204);
      expect(relay.pushTokenCount, 1);
    });

    test('refuses junk', () async {
      expect((await _post('/v1/push/register', 'not json')).$1, 400);
      expect((await _post('/v1/push/register', [1, 2])).$1, 400);
      expect((await _register(tag: 'short')).$1, 400);
      expect((await _register(tag: _tag.toUpperCase())).$1, 400);
      expect((await _register(token: '')).$1, 400);
      expect((await _register(platform: 'blackberry')).$1, 400);
      expect(await _get('/v1/push/register'), startsWith('405'));
      expect(relay.pushTokenCount, 0);
    });

    test('refuses new tags once full, but keeps updating known ones', () async {
      await relay.close();
      await _start(options: const RelayOptions(maxPushTokens: 1));

      expect((await _register()).$1, 204);
      expect((await _register(tag: _otherTag)).$1, 503);
      expect((await _register(token: 'rotated')).$1, 204);
      expect(relay.pushTokenCount, 1);
    });
  });

  group('push with no delivery configured (the default)', () {
    setUp(_start);

    test('registers fine but answers push requests with 503', () async {
      expect((await _register()).$1, 204);

      final (status, body) = await _post('/v1/push', {
        'tag': _tag,
        'payload': 'b3BhcXVl',
      });

      expect(status, 503);
      expect(body, contains('push delivery not configured'));
    });
  });

  group('push through the delivery boundary', () {
    late FakeDelivery delivery;

    setUp(() async {
      delivery = FakeDelivery();
      await _start(
        options: RelayOptions(delivery: delivery, maxPushPayloadBytes: 64),
      );
    });

    test('forwards the opaque payload to the registered token', () async {
      await _register(token: 'fcm-abc', platform: 'ios');

      final (status, body) = await _post('/v1/push', {
        'tag': _tag,
        'payload': 'c2VhbGVkLWJ5dGVz',
      });

      expect(status, 202);
      expect(body, contains('accepted'));
      expect(delivery.delivered.single, (
        token: 'fcm-abc',
        platform: 'ios',
        payload: 'c2VhbGVkLWJ5dGVz',
      ));
    });

    test('an unknown tag is 404', () async {
      final (status, _) = await _post('/v1/push', {
        'tag': _otherTag,
        'payload': 'b3BhcXVl',
      });

      expect(status, 404);
      expect(delivery.delivered, isEmpty);
    });

    test('refuses junk and oversize without delivering', () async {
      await _register();

      expect((await _post('/v1/push', 'not json')).$1, 400);
      expect((await _post('/v1/push', {'tag': _tag})).$1, 400);
      expect(
        (await _post('/v1/push', {'tag': _tag, 'payload': 'no spaces!'})).$1,
        400,
      );
      expect(
        (await _post('/v1/push', {'tag': _tag, 'payload': 'A' * 65})).$1,
        413,
      );
      expect(await _get('/v1/push'), startsWith('405'));
      expect(delivery.delivered, isEmpty);
    });

    test('a failed delivery is 502 and keeps the registration', () async {
      await _register();
      delivery.failure = const PushDeliveryException('fcm answered 500');

      expect((await _post('/v1/push', {'tag': _tag, 'payload': 'YQ'})).$1, 502);

      delivery.failure = null;
      expect((await _post('/v1/push', {'tag': _tag, 'payload': 'YQ'})).$1, 202);
    });

    test('a gone token is 410 and its registration is dropped', () async {
      await _register();
      delivery.failure = const PushTokenGoneException();

      expect((await _post('/v1/push', {'tag': _tag, 'payload': 'YQ'})).$1, 410);

      expect(relay.pushTokenCount, 0);
      delivery.failure = null;
      expect((await _post('/v1/push', {'tag': _tag, 'payload': 'YQ'})).$1, 404);
    });
  });

  group('limits and privacy', () {
    test('push posts share the per-IP rate limit', () async {
      await _start(options: const RelayOptions(connectionsPerMinute: 2));

      expect((await _register()).$1, 204);
      expect((await _register(token: 'again')).$1, 204);
      expect((await _register(token: 'limited')).$1, 429);
    });

    test('logs never name a tag, a token or a payload', () async {
      final lines = <String>[];
      await _start(
        options: RelayOptions(delivery: FakeDelivery(), onLog: lines.add),
      );

      await _register(token: 'secret-fcm-token');
      await _post('/v1/push', {'tag': _tag, 'payload': 'c2VjcmV0cGF5bG9hZA'});
      await _post('/v1/push', {'tag': _otherTag, 'payload': 'YQ'});

      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line, isNot(contains(_tag)));
        expect(line, isNot(contains('secret')));
      }
      expect(lines, contains('a push token registered (1 held)'));
      expect(lines, contains('a push forwarded'));
    });
  });

  group('the FCM sender class', () {
    test('is absent when the environment names no service account', () {
      expect(FcmHttpV1Sender.fromEnvironment(const {}), isNull);
      expect(
        FcmHttpV1Sender.fromEnvironment(const {kServiceAccountEnvVar: '  '}),
        isNull,
      );
    });

    test('reads the file the environment names', () {
      final sender = FcmHttpV1Sender.fromEnvironment(
        const {kServiceAccountEnvVar: '/etc/fcm.json'},
        readFile: (path) {
          expect(path, '/etc/fcm.json');
          return '{"project_id": "chitragupta-test"}';
        },
      );

      expect(sender!.projectId, 'chitragupta-test');
    });

    test('refuses a service account that is not one', () {
      expect(
        () => FcmHttpV1Sender.fromServiceAccountJson('not json'),
        throwsFormatException,
      );
      expect(
        () => FcmHttpV1Sender.fromServiceAccountJson('{"type": "whatever"}'),
        throwsFormatException,
      );
    });

    test('builds a data-only high-priority v1 message', () {
      final message = FcmHttpV1Sender.messageFor(
        token: 'device-token',
        payload: 'b3BhcXVl',
      );

      expect(message, {
        'message': {
          'token': 'device-token',
          'data': {'payload': 'b3BhcXVl'},
          'android': {'priority': 'HIGH'},
          'apns': {
            'headers': {'apns-priority': '10'},
          },
        },
      });
      // Deliberately no `notification` block: the text is inside the
      // ciphertext, decrypted and rendered on the phone.
      expect((message['message']! as Map).containsKey('notification'), isFalse);
    });
  });
}
