import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _key = kHooksListenIdVector;
const _hook = 'fedcba9876543210fedcba9876543210';

late RelayServer relay;

Future<void> _start({RelayOptions options = const RelayOptions()}) async {
  relay = await RelayServer.bind(
    address: '127.0.0.1',
    port: 0,
    options: options,
  );
}

/// A server's listener: the frames it got, and a way to answer.
class _Listener {
  _Listener(this.socket) {
    socket.stream.listen((frame) {
      final read = HookFrame.tryDecode(frame);
      if (read is HooksReady) _ready.complete(read);
      if (read is HookCall) calls.add(read);
    }, onDone: () => closed.complete(socket.closeCode));
  }

  final WebSocketChannel socket;
  final _ready = Completer<HooksReady>();
  final calls = StreamController<HookCall>();
  final closed = Completer<int?>();

  Future<HooksReady> get ready => _ready.future;

  void answer(HookCall call, int status, Map<String, Object?> body) => socket
      .sink
      .add(HookAnswer(id: call.id, status: status, body: body).encode());
}

Future<_Listener> _listen({String prefix = ''}) async {
  final channel = IOWebSocketChannel.connect(
    Uri.parse('ws://127.0.0.1:${relay.port}$prefix/v1/hooks/${_key.key}'),
  );
  await channel.ready;
  final listener = _Listener(channel);
  await listener.ready;
  return listener;
}

typedef _Answer = ({int status, Map<String, Object?> body, String allow});

Future<_Answer> _call({
  String method = 'POST',
  String listenId = '',
  String hookId = _hook,
  List<int> body = const [],
  Map<String, String> headers = const {},
  String prefix = '',
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse(
        'http://127.0.0.1:${relay.port}$prefix/h/'
        '${listenId.isEmpty ? _key.id : listenId}/$hookId',
      ),
    );
    headers.forEach(request.headers.set);
    if (body.isNotEmpty) request.add(body);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Map<String, Object?> json = {};
    try {
      json = jsonDecode(text) as Map<String, Object?>;
    } on Object {
      // A plain-text answer (a bare 404) reads as an empty body.
    }
    return (
      status: response.statusCode,
      body: json,
      allow: response.headers.value('allow') ?? '',
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  tearDown(() async => relay.close());

  test('the listen id derivation matches the contract vector', () async {
    await _start();
    expect(hooksListenIdOf(_key.key), _key.id);
  });

  group('the listener', () {
    setUp(_start);

    test('is told the listen id its key derives to', () async {
      final listener = await _listen();
      expect((await listener.ready).listenId, _key.id);
      expect((await listener.ready).version, kHooksProtocolVersion);
    });

    test('a malformed key is an unknown path', () async {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${relay.port}/v1/hooks/abc'),
      );
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);
      expect(response.statusCode, 404);
    });

    test('a second listener replaces the first', () async {
      final first = await _listen();
      final second = await _listen();
      expect(await first.closed.future, kCloseReplaced);
      final pending = _call(body: utf8.encode('{}'));
      final call = await second.calls.stream.first;
      second.answer(call, 202, {'session': 's2'});
      expect((await pending).body, {'session': 's2'});
    });

    test('is not a rendezvous and holds none', () async {
      await _listen();
      expect(relay.rendezvousCount, 0);
      expect(relay.hookListenerCount, 1);
    });
  });

  group('a call', () {
    setUp(_start);

    test('is forwarded with its method, chosen headers, ip and raw body, '
        'and answered with the server status and body', () async {
      final listener = await _listen();
      final body = utf8.encode('{"action":"opened","x":"é"}');
      final pending = _call(
        body: body,
        headers: {
          'content-type': 'application/json',
          'x-hub-signature-256': 'sha256=ab',
          'x-github-delivery': 'd-1',
          'cookie': 'secret=1',
          'authorization': 'Bearer nope',
        },
      );
      final call = await listener.calls.stream.first;
      expect(call.method, 'POST');
      expect(call.hookId, _hook);
      expect(call.body, body);
      expect(call.ip, '127.0.0.1');
      expect(call.headers['content-type'], 'application/json');
      expect(call.headers['x-hub-signature-256'], 'sha256=ab');
      expect(call.headers['x-github-delivery'], 'd-1');
      expect(call.headers.containsKey('cookie'), isFalse);
      expect(call.headers.containsKey('authorization'), isFalse);
      listener.answer(call, 202, {'session': 's1'});
      final answer = await pending;
      expect(answer.status, 202);
      expect(answer.body, {'session': 's1'});
    });

    test('with no listener is 503 server offline', () async {
      final answer = await _call(body: utf8.encode('{}'));
      expect(answer.status, HookStatus.serverOffline);
      expect(answer.body, {'error': 'server offline'});
    });

    test('above the body cap is 413 and never reaches the server', () async {
      final listener = await _listen();
      var forwarded = false;
      listener.calls.stream.listen((_) => forwarded = true);
      // A raw socket: an HTTP client can see the early answer as a reset, and
      // what matters is the status line a caller is sent.
      final socket = await Socket.connect('127.0.0.1', relay.port);
      socket.write(
        'POST /h/${_key.id}/$_hook HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Length: ${kHookMaxBodyBytes + 1}\r\n'
        '\r\n',
      );
      socket.add(List<int>.filled(kHookMaxBodyBytes + 1, 32));
      await socket.flush();
      final response = StringBuffer();
      await for (final chunk in socket.timeout(const Duration(seconds: 5))) {
        response.write(latin1.decode(chunk));
        if (response.toString().contains('\r\n\r\n')) break;
      }
      socket.destroy();
      expect(response.toString().split('\r\n').first, contains('413'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forwarded, isFalse);
    });

    test('with any other method is 405', () async {
      await _listen();
      for (final method in ['GET', 'PUT', 'DELETE']) {
        final answer = await _call(method: method);
        expect(answer.status, HookStatus.methodNotAllowed, reason: method);
        expect(answer.allow, 'POST');
      }
    });

    test('to a malformed hook path is 404', () async {
      await _listen();
      expect((await _call(hookId: 'nope')).status, 404);
      expect((await _call(listenId: 'nope')).status, 404);
    });

    test('a bad answer is 502', () async {
      final listener = await _listen();
      final pending = _call(body: utf8.encode('{}'));
      final call = await listener.calls.stream.first;
      listener.socket.sink.add(
        jsonEncode({'type': 'answer', 'id': call.id, 'status': 42, 'body': {}}),
      );
      expect((await pending).status, HookStatus.badAnswer);
    });
  });

  test('a call the server does not answer in time is 504', () async {
    await _start(
      options: const RelayOptions(
        hookAnswerTimeout: Duration(milliseconds: 200),
      ),
    );
    final listener = await _listen();
    final pending = _call(body: utf8.encode('{}'));
    await listener.calls.stream.first;
    final answer = await pending;
    expect(answer.status, HookStatus.timedOut);
  });

  test('calls are rate limited per listen id', () async {
    await _start(
      options: const RelayOptions(
        hookCallsPerMinute: 2,
        connectionsPerMinute: 0,
      ),
    );
    final listener = await _listen();
    listener.calls.stream.listen((call) => listener.answer(call, 202, {}));
    expect((await _call(body: [1])).status, 202);
    expect((await _call(body: [1])).status, 202);
    final third = await _call(body: [1]);
    expect(third.status, HookStatus.slowDown);
    expect(third.body, {'error': 'slow down'});
  });

  test('a listener that leaves fails its waiting calls with 503', () async {
    await _start();
    final listener = await _listen();
    final pending = _call(body: utf8.encode('{}'));
    await listener.calls.stream.first;
    await listener.socket.sink.close();
    expect((await pending).status, HookStatus.serverOffline);
  });

  test('under an access token both routes live behind the prefix', () async {
    final token = 'A-_z' * 8;
    await _start(options: RelayOptions(accessToken: token));
    final listener = await _listen(prefix: '/k/$token');
    final pending = _call(body: [1], prefix: '/k/$token');
    final call = await listener.calls.stream.first;
    listener.answer(call, 202, {'session': 's'});
    expect((await pending).status, 202);
    expect((await _call(body: [1])).status, 404);
  });

  test('a rendezvous still pairs beside a listener', () async {
    await _start();
    await _listen();
    const id = '0123456789abcdef0123456789abcdef';
    final a = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${relay.port}/v1/$id'),
    );
    final b = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${relay.port}/v1/$id'),
    );
    await a.ready;
    await b.ready;
    a.sink.add('hello');
    expect(await b.stream.first, 'hello');
    await a.sink.close();
    await b.sink.close();
  });
}
