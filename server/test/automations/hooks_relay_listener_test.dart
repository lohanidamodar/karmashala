import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/src/automations/webhooks/hooks_relay_listener.dart';
import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:karmashala_remote/remote.dart' show Backoff;
import 'package:test/test.dart';

const _key = kHooksListenIdVector;
const _hook = 'fedcba9876543210fedcba9876543210';

Future<void> _until(bool Function() done, {String what = 'condition'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<(int, String)> _post(int port, {String prefix = ''}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port$prefix/h/${_key.id}/$_hook'),
    );
    request.add(utf8.encode('{"x":1}'));
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}

void main() {
  late List<HookCall> received;
  late HooksRelayListener listener;

  HooksRelayListener make() => HooksRelayListener(
    answer: (call) async {
      received.add(call);
      return HookAnswer(id: call.id, status: 202, body: {'session': 's1'});
    },
    backoff: () => Backoff(
      initial: const Duration(milliseconds: 20),
      maximum: const Duration(milliseconds: 100),
    ),
  );

  setUp(() {
    received = [];
    listener = make();
  });
  tearDown(() => listener.close());

  test('listens on the relay and answers its calls', () async {
    final relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    addTearDown(relay.close);
    listener.listenOn(Uri.parse('ws://127.0.0.1:${relay.port}'), _key.key);
    await _until(() => listener.state == HooksListenerState.listening);
    expect(listener.listenId, _key.id);
    final (status, body) = await _post(relay.port);
    expect(status, 202);
    expect(jsonDecode(body), {'session': 's1'});
    expect(received.single.hookId, _hook);
    expect(received.single.body, utf8.encode('{"x":1}'));
  });

  test('keeps a self-hoster prefix such as /k/<token>', () async {
    final token = 'A-_z' * 8;
    final relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: RelayOptions(accessToken: token),
    );
    addTearDown(relay.close);
    listener.listenOn(
      Uri.parse('ws://127.0.0.1:${relay.port}/k/$token'),
      _key.key,
    );
    await _until(() => listener.state == HooksListenerState.listening);
    expect((await _post(relay.port, prefix: '/k/$token')).$1, 202);
  });

  test('reconnects when the relay goes away and comes back', () async {
    var relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    final port = relay.port;
    listener.listenOn(Uri.parse('ws://127.0.0.1:$port'), _key.key);
    await _until(() => listener.state == HooksListenerState.listening);
    await relay.close();
    await _until(
      () => listener.state != HooksListenerState.listening,
      what: 'the drop',
    );
    relay = await RelayServer.bind(address: '127.0.0.1', port: port);
    addTearDown(relay.close);
    await _until(
      () => listener.state == HooksListenerState.listening,
      what: 'the reconnect',
    );
    expect((await _post(port)).$1, 202);
    expect(listener.connections, greaterThanOrEqualTo(2));
  });

  test('stops when told there is nothing to listen for', () async {
    final relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    addTearDown(relay.close);
    listener.listenOn(Uri.parse('ws://127.0.0.1:${relay.port}'), _key.key);
    await _until(() => listener.state == HooksListenerState.listening);
    listener.listenOn(null, null);
    expect(listener.state, HooksListenerState.off);
    await _until(() => relay.hookListenerCount == 0, what: 'the hang-up');
    expect((await _post(relay.port)).$1, HookStatus.serverOffline);
  });

  test('a relay that predates webhooks is retried, said in words', () async {
    final old = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => old.close(force: true));
    old.listen((request) {
      request.response.statusCode = 404;
      request.response.close();
    });
    listener.listenOn(Uri.parse('ws://127.0.0.1:${old.port}'), _key.key);
    await _until(() => listener.attempts >= 2, what: 'two attempts');
    expect(listener.state, HooksListenerState.waiting);
    expect(listener.problem, contains('webhooks'));
  });
}
