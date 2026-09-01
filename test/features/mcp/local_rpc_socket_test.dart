import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The owner-only local RPC transport.
///
/// Loop 48 replaced a Windows-only named pipe with a unix domain socket on all
/// three platforms. The pipe served blocking Win32 I/O from an isolate, which
/// no longer mattered for correctness but did stop the process exiting: a
/// blocking FFI call cannot be interrupted, so the VM could not shut the
/// isolate down and quitting the app never completed. These tests pin the
/// replacement's contract.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('chitra_ipc_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String socketIn(Directory dir) => p.join(dir.path, 'rpc.sock');

  group('LocalRpcServer', () {
    test('round-trips a request on every supported platform', () async {
      expect(localSocketsSupported, isTrue);
      final server = await LocalRpcServer.bind(
        socketIn(tmp),
        (request) => 'ok:$request',
      );
      addTearDown(server.close);

      expect(await LocalRpcClient.call(server.path, 'ping'), 'ok:ping');
    });

    test('serves several calls, including from separate connections', () async {
      final server = await LocalRpcServer.bind(
        socketIn(tmp),
        (request) async => 'ok:$request',
      );
      addTearDown(server.close);

      final replies = await Future.wait([
        for (var i = 0; i < 5; i++) LocalRpcClient.call(server.path, 'r$i'),
      ]);

      expect(replies, ['ok:r0', 'ok:r1', 'ok:r2', 'ok:r3', 'ok:r4']);
    });

    test(
      'a handler that throws answers with an error, not a dead socket',
      () async {
        final server = await LocalRpcServer.bind(
          socketIn(tmp),
          (_) => throw StateError('boom'),
        );
        addTearDown(server.close);

        final raw = await LocalRpcClient.call(server.path, 'ping');
        expect(jsonDecode(raw), {'ok': false, 'error': 'Bad state: boom'});
      },
    );

    test('removes its socket file on close', () async {
      final server = await LocalRpcServer.bind(socketIn(tmp), (r) => r);
      expect(File(server.path).existsSync(), isTrue);
      await server.close();
      expect(File(server.path).existsSync(), isFalse);
    });

    test('refuses to bind over a socket another process is serving', () async {
      final first = await LocalRpcServer.bind(socketIn(tmp), (r) => r);
      addTearDown(first.close);

      expect(
        () => LocalRpcServer.bind(socketIn(tmp), (r) => r),
        throwsA(isA<StateError>()),
      );
    });

    test('replaces a socket file left behind by a crash', () async {
      // A plain file standing where the socket was: nothing is listening on it,
      // which is exactly what a killed process leaves on POSIX.
      File(socketIn(tmp)).writeAsStringSync('');

      final server = await LocalRpcServer.bind(socketIn(tmp), (r) => 'ok:$r');
      addTearDown(server.close);

      expect(await LocalRpcClient.call(server.path, 'ping'), 'ok:ping');
    });

    test(
      'refuses a request over the 1 MiB cap rather than buffering it',
      () async {
        final server = await LocalRpcServer.bind(socketIn(tmp), (r) => 'ok');
        addTearDown(server.close);

        expect(
          () => LocalRpcClient.call(server.path, 'x' * (kLocalRpcMaxBytes + 1)),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test(
      'refuses a request containing a newline, which would frame as two',
      () async {
        final server = await LocalRpcServer.bind(socketIn(tmp), (r) => 'ok');
        addTearDown(server.close);

        expect(
          () => LocalRpcClient.call(server.path, 'a\nb'),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });

  group('restrictDirectoryToCurrentUser', () {
    test('reports success on the socket directory', () async {
      final dir = Directory(p.join(tmp.path, 'ipc'))..createSync();
      expect(await restrictDirectoryToCurrentUser(dir), isTrue);
      // Still usable by us afterwards — the point of granting before stripping
      // inheritance.
      final server = await LocalRpcServer.bind(
        p.join(dir.path, 'rpc.sock'),
        (r) => 'ok:$r',
      );
      addTearDown(server.close);
      expect(await LocalRpcClient.call(server.path, 'ping'), 'ok:ping');
    });
  });

  group('LauncherControlServer over the socket', () {
    late ProviderContainer container;
    late LauncherControlServer server;

    setUp(() async {
      container = ProviderContainer(
        overrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
      );
      server = LauncherControlServer(container);
      await server.start(
        bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
    });

    tearDown(() async {
      await server.stop();
      container.dispose();
    });

    Map<String, Object?> handshake() =>
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;

    test('publishes the socket path in the handshake file', () {
      final path = handshake()['socketPath'] as String?;
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
    });

    test('dispatches an authenticated tool call', () async {
      final json = handshake();
      final raw = await LocalRpcClient.call(
        json['socketPath']! as String,
        jsonEncode({
          'tool': '__list_tools__',
          'arguments': const <String, Object?>{},
          'token': json['token'],
        }),
      );
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      expect(decoded['ok'], isTrue);
      expect(decoded['result'], isA<List<Object?>>());
    });

    test('refuses a call with the wrong token', () async {
      final json = handshake();
      final raw = await LocalRpcClient.call(
        json['socketPath']! as String,
        jsonEncode({
          'tool': '__list_tools__',
          'arguments': const <String, Object?>{},
          'token': 'not-the-token',
        }),
      );
      expect(jsonDecode(raw), {'ok': false, 'error': 'Unauthorized.'});
    });

    test('refuses a call with no token at all', () async {
      final json = handshake();
      final raw = await LocalRpcClient.call(
        json['socketPath']! as String,
        jsonEncode({
          'tool': '__list_tools__',
          'arguments': const <String, Object?>{},
        }),
      );
      expect(jsonDecode(raw), {'ok': false, 'error': 'Unauthorized.'});
    });

    test('/rpc over loopback HTTP is closed while the socket is up', () async {
      final json = handshake();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/rpc'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${json['token']}',
      );
      request.write(jsonEncode({'tool': '__list_tools__'}));
      final response = await request.close();
      await response.drain<void>();

      // Not 401: the token is right. The transport is simply not open.
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('stop() takes the socket away with it', () async {
      final path = handshake()['socketPath']! as String;
      await server.stop();
      expect(File(path).existsSync(), isFalse);
    });
  });

  group('LauncherControlServer without the socket', () {
    test('/rpc falls back to authenticated loopback HTTP', () async {
      final container = ProviderContainer(
        overrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
      );
      final server = LauncherControlServer(container);
      await server.start(
        bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
        useLocalSocket: false,
      );
      addTearDown(() async {
        await server.stop();
        container.dispose();
      });

      final json =
          jsonDecode(
                File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(json['socketPath'], isNull);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/rpc'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${json['token']}',
      );
      request.write(jsonEncode({'tool': '__list_tools__'}));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, HttpStatus.ok);
      expect((jsonDecode(body) as Map)['ok'], isTrue);
    });
  });
}
