/// A relay with an access token answers only under `/k/<token>/`, and says
/// exactly what it says about any unknown path to everybody else.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_relay/karmashala_relay.dart';
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _rendezvous = '0123456789abcdef0123456789abcdef';
const _token = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const _wrong = 'a1b2c3d4e5f60718293a4b5c6d7e8f91';

late RelayServer relay;

/// What `RelayTransport.endpointFor` builds from a base URL with a path prefix:
/// the prefix is kept and `/v1/<rendezvous>` goes after it.
Uri _endpoint(Uri base, String rendezvous) =>
    base.replace(path: '${base.path}/v1/$rendezvous');

Uri _base([String token = _token]) =>
    Uri.parse('ws://127.0.0.1:${relay.port}/k/$token');

Future<(int, String)> _request(
  String method,
  String path, [
  String? body,
]) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${relay.port}$path'),
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  } finally {
    client.close(force: true);
  }
}

/// The literal status line a client is sent for an upgrade request.
Future<String> _rawUpgrade(String path) async {
  final socket = await Socket.connect('127.0.0.1', relay.port);
  socket.write(
    'GET $path HTTP/1.1\r\n'
    'Host: 127.0.0.1:${relay.port}\r\n'
    'Connection: Upgrade\r\n'
    'Upgrade: websocket\r\n'
    'Sec-WebSocket-Version: 13\r\n'
    'Sec-WebSocket-Key: ${base64Encode(List<int>.filled(16, 7))}\r\n'
    '\r\n',
  );
  await socket.flush();
  final response = StringBuffer();
  await for (final chunk in socket.timeout(const Duration(seconds: 5))) {
    response.write(latin1.decode(chunk));
    if (response.toString().contains('\r\n\r\n')) break;
  }
  socket.destroy();
  return response.toString().split('\r\n').first;
}

void main() {
  final logged = <String>[];

  setUp(() async {
    logged.clear();
    relay = await RelayServer.bind(
      address: '127.0.0.1',
      port: 0,
      options: RelayOptions(accessToken: _token, onLog: logged.add),
    );
  });
  tearDown(() async => relay.close());

  test('a base URL carrying the token pairs two sockets', () async {
    final url = _endpoint(_base(), _rendezvous);
    expect(url.path, '/k/$_token/v1/$_rendezvous');
    final WebSocketChannel host = IOWebSocketChannel.connect(url);
    await host.ready;
    final WebSocketChannel phone = IOWebSocketChannel.connect(url);
    await phone.ready;

    host.sink.add(Uint8List.fromList([1, 2, 3]));
    expect(await phone.stream.first, [1, 2, 3]);
    await host.sink.close();
    await phone.sink.close();
  });

  test('the bare path and a wrong token are both just "not found"', () async {
    final unknown = await _request('GET', '/nothing-here');
    expect(unknown.$1, 404);

    expect(await _rawUpgrade('/v1/$_rendezvous'), 'HTTP/1.1 404 Not Found');
    expect(
      await _rawUpgrade('/k/$_wrong/v1/$_rendezvous'),
      'HTTP/1.1 404 Not Found',
    );
    // No oracle: a near miss reads exactly as a path that never existed.
    expect(await _request('GET', '/v1/$_rendezvous'), unknown);
    expect(await _request('GET', '/k/$_wrong/v1/$_rendezvous'), unknown);
    expect(await _request('GET', '/k/$_wrong/healthz'), unknown);
    expect(await _request('GET', '/k/$_token'), unknown);
    expect(relay.rendezvousCount, 0);
  });

  test('healthz and the push endpoints are behind the token too', () async {
    final unknown = await _request('GET', '/nothing-here');
    expect(await _request('GET', '/healthz'), unknown);
    expect(await _request('POST', '/v1/push', '{}'), unknown);
    expect(await _request('POST', '/v1/push/register', '{}'), unknown);

    final health = await _request('GET', '/k/$_token/healthz');
    expect(health.$1, 200);
    expect((jsonDecode(health.$2) as Map)['status'], 'ok');

    final registered = await _request(
      'POST',
      '/k/$_token/v1/push/register',
      jsonEncode({'tag': _rendezvous, 'token': 'fcm', 'platform': 'android'}),
    );
    expect(registered.$1, 204);
  });

  test('the token is never logged', () async {
    await _request('GET', '/k/$_token/healthz');
    await _request('GET', '/k/$_wrong/healthz');
    final url = _endpoint(_base(), _rendezvous);
    final socket = IOWebSocketChannel.connect(url);
    await socket.ready;
    await socket.sink.close();
    expect(logged.join('\n'), isNot(contains(_token)));
    expect(logged.join('\n'), isNot(contains(_wrong)));
  });

  test('a token too short to be one is refused, not served', () async {
    for (final bad in ['', 'short', 'has/a/slash-${'x' * 32}']) {
      await expectLater(
        RelayServer.bind(
          address: '127.0.0.1',
          port: 0,
          options: RelayOptions(accessToken: bad),
        ),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(isUsableRelayToken(_token), isTrue);
  });

  test('no token leaves every path where it was', () async {
    await relay.close();
    relay = await RelayServer.bind(address: '127.0.0.1', port: 0);
    expect((await _request('GET', '/healthz')).$1, 200);
    expect((await _request('GET', '/k/$_token/healthz')).$1, 404);
  });
}
