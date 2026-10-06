/// Push after a relay move: the token is registered again on the new relay,
/// and a relay that answers 503 (no FCM secret yet) is "push unavailable" for
/// a while — never retried on every push — while the old relay, if it still
/// delivers, carries the push meanwhile.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_remote/push.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

final _oldRelay = Uri.parse('wss://old.example.org');
final _newRelay = Uri.parse('wss://new.example.org');

PairedDevice _moved() => PairedDevice(
  id: 'a' * 32,
  name: 'OPPO',
  deviceKey: Uint8List.fromList(List.generate(32, (i) => i)),
  capabilities: CapabilitySet.all,
  generation: 1,
  createdAt: DateTime.utc(2026, 10, 6),
  pushToken: 'fcm-token-1',
  pushPlatform: 'android',
  relayUrl: _newRelay.toString(),
  relayMovedFrom: _oldRelay.toString(),
);

void main() {
  late List<String> posts;
  late Set<String> unconfigured;
  late Set<String> pushRefused;
  late DateTime now;
  late List<String> log;

  Future<({int status, String body})> poster(Uri url, String body) async {
    final register = url.path.endsWith('/register');
    posts.add('${url.host} ${register ? 'register' : 'push'}');
    if (unconfigured.contains(url.host)) {
      return (status: 503, body: 'push is not configured\n');
    }
    if (!register && pushRefused.contains(url.host)) {
      return (status: 503, body: 'push is not configured\n');
    }
    return register ? (status: 204, body: '') : (status: 202, body: '');
  }

  PushFanout fanout({List<Uri> fallbacks = const []}) => PushFanout(
    devices: () => [_moved()],
    hasLiveLink: (_) => false,
    clientFor: (_) => RelayPushClient(relay: _newRelay, post: poster),
    fallbackClientsFor: (_) => [
      for (final relay in fallbacks)
        RelayPushClient(relay: relay, post: poster),
    ],
    now: () => now,
    onLog: log.add,
  );

  setUp(() {
    posts = [];
    unconfigured = {};
    pushRefused = {};
    now = DateTime.utc(2026, 10, 6, 12);
    log = [];
  });

  Future<void> notify(PushFanout fanout) =>
      fanout.notifyAttention(sessionId: 's1', title: 'Done', kind: 'finished');

  test('the token is registered again on the new relay, and the push goes '
      'there', () async {
    await notify(fanout(fallbacks: [_oldRelay]));
    expect(posts, ['new.example.org register', 'new.example.org push']);
  });

  test('a 503 on the new relay is push unavailable there: the old relay '
      'carries it, and the new one is not asked again on every push', () async {
    unconfigured.add('new.example.org');
    final push = fanout(fallbacks: [_oldRelay]);

    await notify(push);
    expect(posts, [
      'new.example.org register',
      'old.example.org register',
      'old.example.org push',
    ]);
    expect(log.join('\n'), contains('push unavailable at new.example.org'));

    posts.clear();
    await notify(push);
    await notify(push);
    expect(posts, ['old.example.org push', 'old.example.org push']);
  });

  test('once the wait is over the new relay is asked again, and takes over '
      'when it has been configured', () async {
    unconfigured.add('new.example.org');
    final push = fanout(fallbacks: [_oldRelay]);
    await notify(push);

    unconfigured.clear();
    now = now.add(kPushUnavailableRetry + const Duration(seconds: 1));
    posts.clear();
    await notify(push);
    expect(posts, ['new.example.org register', 'new.example.org push']);
  });

  test('a push itself answered 503 falls back the same way', () async {
    pushRefused.add('new.example.org');
    await notify(fanout(fallbacks: [_oldRelay]));
    expect(posts, [
      'new.example.org register',
      'new.example.org push',
      'old.example.org register',
      'old.example.org push',
    ]);
  });

  test('with nowhere else to go, a 503 is one request per wait, not a '
      'loop', () async {
    unconfigured.add('new.example.org');
    final push = fanout();
    for (var i = 0; i < 5; i++) {
      await notify(push);
    }
    expect(posts, ['new.example.org register']);
    expect(
      log.where((line) => line.contains('push unavailable')),
      hasLength(1),
    );
  });

  test('nothing in the log names the token or the device', () async {
    unconfigured.add('new.example.org');
    await notify(fanout(fallbacks: [_oldRelay]));
    final text = jsonEncode(log);
    expect(text, isNot(contains('fcm-token-1')));
    expect(text, isNot(contains('a' * 32)));
  });
}
