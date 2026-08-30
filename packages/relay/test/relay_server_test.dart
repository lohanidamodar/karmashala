import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chitragupta_relay/chitragupta_relay.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _rendezvous = '0123456789abcdef0123456789abcdef';
const _other = 'fedcba9876543210fedcba9876543210';

late RelayServer relay;

Future<void> _start({RelayOptions options = const RelayOptions()}) async {
  relay = await RelayServer.bind(
    address: '127.0.0.1',
    port: 0,
    options: options,
  );
}

Uri _url(String rendezvous) =>
    Uri.parse('ws://127.0.0.1:${relay.port}/v1/$rendezvous');

Future<WebSocketChannel> _connect([String rendezvous = _rendezvous]) async {
  final channel = IOWebSocketChannel.connect(_url(rendezvous));
  await channel.ready;
  return channel;
}

/// Sends an upgrade request by hand so the HTTP status is visible.
Future<HttpClientResponse> _rawUpgrade(String rendezvous) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${relay.port}/v1/$rendezvous'),
    );
    request.headers
      ..set('connection', 'Upgrade')
      ..set('upgrade', 'websocket')
      ..set('sec-websocket-version', '13')
      ..set('sec-websocket-key', base64Encode(List<int>.filled(16, 7)));
    return await request.close();
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
    return '${response.statusCode} ${await response.transform(utf8.decoder).join()}';
  } finally {
    client.close(force: true);
  }
}

void main() {
  tearDown(() async => relay.close());

  group('pairing two sockets', () {
    setUp(_start);

    test('forwards frames both ways, verbatim', () async {
      final host = await _connect();
      final phone = await _connect();
      final fromHost = StreamQueue<Object?>(phone.stream);
      final fromPhone = StreamQueue<Object?>(host.stream);

      host.sink.add(Uint8List.fromList([1, 2, 3]));
      phone.sink.add(Uint8List.fromList([9, 8]));

      expect(await fromHost.next, [1, 2, 3]);
      expect(await fromPhone.next, [9, 8]);
    });

    test('carries a megabyte frame', () async {
      final host = await _connect();
      final phone = await _connect();
      final frame = Uint8List.fromList(
        List<int>.generate(1024 * 1024, (i) => i & 0xff),
      );

      host.sink.add(frame);

      final got = (await phone.stream.first)! as List<int>;
      expect(got.length, frame.length);
      expect(got.sublist(0, 16), frame.sublist(0, 16));
    });

    test('holds what the first sent until the second arrives', () async {
      final host = await _connect();
      host.sink.add(Uint8List.fromList([1]));
      host.sink.add(Uint8List.fromList([2]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final phone = await _connect();

      expect(await phone.stream.take(2).toList(), [
        [1],
        [2],
      ]);
    });

    test('keeps two rendezvous apart', () async {
      final hostA = await _connect();
      final phoneA = await _connect();
      final hostB = await _connect(_other);
      final phoneB = await _connect(_other);

      hostA.sink.add(Uint8List.fromList([0xaa]));
      hostB.sink.add(Uint8List.fromList([0xbb]));

      expect(await phoneA.stream.first, [0xaa]);
      expect(await phoneB.stream.first, [0xbb]);
      expect(relay.rendezvousCount, 2);
    });

    test('closing one end closes the other', () async {
      final host = await _connect();
      final phone = await _connect();

      await host.sink.close();

      expect(await phone.stream.isEmpty, isTrue);
      await _eventually(() => relay.rendezvousCount == 0);
    });

    test('the rendezvous is reusable once both have left', () async {
      final host = await _connect();
      final phone = await _connect();
      await host.sink.close();
      await phone.stream.drain<void>();
      await _eventually(() => relay.rendezvousCount == 0);

      final again = await _connect();
      final againPhone = await _connect();
      again.sink.add(Uint8List.fromList([5]));

      expect(await againPhone.stream.first, [5]);
    });
  });

  group('what it refuses', () {
    setUp(_start);

    test('a third socket on a live rendezvous', () async {
      await _connect();
      await _connect();

      final refused = await _rawUpgrade(_rendezvous);

      expect(refused.statusCode, 409);
      await refused.drain<void>();
    });

    test('and a real client sees the connection fail', () async {
      await _connect();
      await _connect();

      await expectLater(
        IOWebSocketChannel.connect(_url(_rendezvous)).ready,
        throwsA(isA<WebSocketChannelException>()),
      );
    });

    test('a path that is not a rendezvous', () async {
      expect(await _get('/'), startsWith('404'));
      expect(await _get('/v1/'), startsWith('404'));
      expect(
        await _get('/v1/nothex0000000000000000000000000'),
        startsWith('404'),
      );
      expect(await _get('/v1/${_rendezvous.toUpperCase()}'), startsWith('404'));
      expect(await _get('/v2/$_rendezvous'), startsWith('404'));
      expect(await _get('/v1/$_rendezvous/extra'), startsWith('404'));
    });

    test('a rendezvous id of the wrong length', () async {
      expect(await _get('/v1/${_rendezvous.substring(1)}'), startsWith('404'));
      expect(await _get('/v1/${_rendezvous}0'), startsWith('404'));
    });
  });

  group('the lone socket timeout', () {
    setUp(
      () => _start(
        options: const RelayOptions(loneTimeout: Duration(milliseconds: 150)),
      ),
    );

    test('drops a socket nobody joined', () async {
      final lonely = await _connect();

      final closeCode = await lonely.stream.drain<void>().then(
        (_) => lonely.closeCode,
      );

      expect(closeCode, kCloseNoPeer);
      expect(relay.rendezvousCount, 0);
    });

    test('does not fire once a peer has arrived', () async {
      final host = await _connect();
      final phone = await _connect();

      await Future<void>.delayed(const Duration(milliseconds: 400));
      host.sink.add(Uint8List.fromList([1]));

      expect(await phone.stream.first, [1]);
    });
  });

  group('limits', () {
    test('caps how much a lone socket may send before pairing', () async {
      await _start();
      final impatient = await _connect();

      for (var i = 0; i < 20; i++) {
        impatient.sink.add(Uint8List.fromList([i]));
      }

      await impatient.stream.drain<void>();
      expect(impatient.closeCode, kCloseImpatient);
    });

    test('cuts off a frame above the size cap', () async {
      await _start(options: const RelayOptions(maxFrameBytes: 32));
      final host = await _connect();
      final phone = await _connect();

      host.sink.add(Uint8List(64));

      await phone.stream.drain<void>();
      expect(phone.closeCode, kCloseFrameTooLarge);
    });

    test('rate limits new connections per IP', () async {
      await _start(options: const RelayOptions(connectionsPerMinute: 2));

      expect(await _get('/v1/$_rendezvous'), startsWith('404'));
      expect(await _get('/v1/$_other'), startsWith('404'));
      expect(await _get('/v1/$_rendezvous'), startsWith('429'));
    });

    test('the rate limit can be turned off', () async {
      await _start(options: const RelayOptions(connectionsPerMinute: 0));

      for (var i = 0; i < 10; i++) {
        expect(await _get('/v1/$_rendezvous'), startsWith('404'));
      }
    });

    test('refuses a new rendezvous once it is full', () async {
      await _start(options: const RelayOptions(maxRendezvous: 1));
      await _connect();

      expect(await _get('/v1/$_other'), startsWith('503'));
    });
  });

  group('healthz', () {
    setUp(_start);

    test('reports counts and no ids', () async {
      await _connect();
      await _connect(_other);

      final body = await _get('/healthz');

      expect(body, startsWith('200'));
      final json = jsonDecode(body.substring(4)) as Map<String, Object?>;
      expect(json['status'], 'ok');
      expect(json['rendezvous'], 2);
      expect(json['sockets'], 2);
      expect(json['uptime_s'], isA<int>());
      expect(body, isNot(contains(_rendezvous)));
    });
  });

  group('logging', () {
    test('never names a rendezvous', () async {
      final lines = <String>[];
      await _start(options: RelayOptions(onLog: lines.add));

      final host = await _connect();
      final phone = await _connect();
      host.sink.add(Uint8List.fromList([1, 2, 3, 4]));
      await phone.stream.first;
      await _rawUpgrade(_rendezvous).then((r) => r.drain<void>());

      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line, isNot(contains(_rendezvous)));
        expect(line, isNot(contains('1, 2, 3, 4')));
      }
      expect(lines, contains('paired (1 held)'));
      expect(lines, contains('refused a third socket'));
    });
  });

  group('shutting down', () {
    test('closes every live socket', () async {
      await _start();
      final host = await _connect();
      final phone = await _connect();

      await relay.close();

      await host.stream.drain<void>();
      await phone.stream.drain<void>();
      expect(host.closeCode, kCloseNoPeer);
    });
  });
}

/// Polls [condition] until it holds or the deadline passes.
Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A one-at-a-time reader over a stream, so a test can await the next frame
/// without racing the one after it.
class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    _subscription = stream.listen(_buffer.add);
  }

  final List<T> _buffer = [];
  late final StreamSubscription<T> _subscription;

  Future<T> get next async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_buffer.isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('no frame arrived');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return _buffer.removeAt(0);
  }

  Future<void> cancel() => _subscription.cancel();
}
