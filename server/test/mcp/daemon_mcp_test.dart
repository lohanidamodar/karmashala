/// The daemon's MCP endpoint: tokens it issued are honoured across restarts,
/// tool calls go to the connected app, and with no app agents are told so.
/// In-process on temp directories, never on anyone's real host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../serve/pipe_connection.dart';

const _echo = <String, Object?>{
  'name': 'echo',
  'description': 'Answers with who called it.',
  'inputSchema': {'type': 'object'},
};

class _Refusing extends HandshakePermissions {
  const _Refusing();
  @override
  Future<bool> restrictFile(File file, {Object? logger}) async => false;
  @override
  Future<bool> restrictDirectory(Directory dir, {Object? logger}) async =>
      false;
}

void main() {
  late Directory root;
  late HostPaths paths;
  late String dataDir;
  late McpToolRelay relay;
  late HostServer server;
  DaemonMcp? daemon;

  setUp(() {
    root = Directory.systemTemp.createTempSync('kh-mcp');
    paths = HostPaths(Directory(p.join(root.path, 'host')))..ensureDirectory();
    dataDir = p.join(root.path, 'data');
    Directory(dataDir).createSync();
    relay = McpToolRelay(cachePath: paths.mcpToolsPath);
    server = HostServer(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      ptyLibrary: 'libc.so.6',
      mcpTools: relay,
    );
  });

  tearDown(() async {
    await daemon?.close();
    daemon = null;
    root.deleteSync(recursive: true);
  });

  Future<DaemonMcp> start({
    HandshakePermissions permissions = const SystemHandshakePermissions(),
  }) async => daemon = await DaemonMcp.start(
    paths: paths,
    dataDirectory: dataDir,
    relay: relay,
    sessionIsOver: (sessionId) => sessionId == 'ended',
    preferredPort: 0,
    permissions: permissions,
  );

  /// An app on the lifecycle link that runs `echo`, or fails it with [fail].
  Future<HostLifecycleWatch> connectApp({String? fail}) async {
    final (client, host) = PipeEnd.pair();
    unawaited(server.serveConnection(host));
    final watch = await HostLifecycleWatch.over(client, clientId: 'app');
    watch.mcpCalls.listen((call) {
      if (fail != null) {
        watch.answerMcpCall(call.callId, error: fail);
        return;
      }
      watch.answerMcpCall(
        call.callId,
        result: {'caller': call.callerSessionId, 'arguments': call.arguments},
      );
    });
    watch.offerMcpTools([_echo]);
    // The offer is a frame on the link; let it land before calling.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return watch;
  }

  Future<(int, Map<String, Object?>?)> rpc(
    DaemonMcp mcp,
    String token,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${mcp.endpoint.port}/mcp/$token'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': method,
          'params': params,
        }),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return (
        response.statusCode,
        body.isEmpty ? null : jsonDecode(body) as Map<String, Object?>,
      );
    } finally {
      client.close(force: true);
    }
  }

  String textOf(Map<String, Object?>? reply) {
    final result = reply!['result']! as Map<String, Object?>;
    final content = result['content']! as List<Object?>;
    return (content.single! as Map<String, Object?>)['text']! as String;
  }

  bool isError(Map<String, Object?>? reply) =>
      (reply!['result']! as Map<String, Object?>)['isError'] == true;

  group('caller tokens', () {
    test('one the daemon issued is honoured; any other is refused', () async {
      final mcp = await start();
      final key = mcp.credentials.callerKey;
      expect((await rpc(mcp, key.tokenFor('s1'), 'ping')).$1, 200);
      expect((await rpc(mcp, 'not-a-token', 'ping')).$1, 401);
      final forged = McpCallerKey.generate().tokenFor('s1');
      expect((await rpc(mcp, forged, 'ping')).$1, 401);
    });

    test('a token for a session that is over is refused', () async {
      final mcp = await start();
      final token = mcp.credentials.callerKey.tokenFor('ended');
      expect((await rpc(mcp, token, 'ping')).$1, 401);
    });

    test('tokens and the port survive a restart of the daemon', () async {
      final first = await start();
      final token = first.credentials.callerKey.tokenFor('s1');
      final port = first.endpoint.port;
      await first.close();
      daemon = null;

      final second = await start();
      expect(second.endpoint.port, port);
      expect((await rpc(second, token, 'ping')).$1, 200);
    });
  });

  group('forwarding', () {
    test(
      'a tools/call runs in the app as the session its token names',
      () async {
        final mcp = await start();
        await connectApp();
        final (status, reply) = await rpc(
          mcp,
          mcp.credentials.callerKey.tokenFor('s1'),
          'tools/call',
          {
            'name': 'echo',
            // An argument cannot say who is calling.
            'arguments': {'callerSessionId': 'someone-else'},
          },
        );
        expect(status, 200);
        expect(isError(reply), isFalse);
        final answered = jsonDecode(textOf(reply)) as Map<String, Object?>;
        expect(answered['caller'], 's1');
        expect(answered['arguments'], {'callerSessionId': 'someone-else'});
      },
    );

    test('a tool the app fails comes back as an isError result', () async {
      final mcp = await start();
      await connectApp(fail: 'Bad state: boom');
      final (_, reply) = await rpc(
        mcp,
        mcp.credentials.callerKey.tokenFor('s1'),
        'tools/call',
        {'name': 'echo'},
      );
      expect(isError(reply), isTrue);
      expect(textOf(reply), 'Error: Bad state: boom');
    });

    test('with no app connected, a call says the app is not running, and '
        'the last catalogue is still listed', () async {
      final mcp = await start();
      final app = await connectApp();
      await app.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final token = mcp.credentials.callerKey.tokenFor('s1');
      final (_, listed) = await rpc(mcp, token, 'tools/list');
      final tools = (listed!['result']! as Map<String, Object?>)['tools'];
      expect([for (final t in tools! as List) (t as Map)['name']], ['echo']);

      final (_, reply) = await rpc(mcp, token, 'tools/call', {'name': 'echo'});
      expect(isError(reply), isTrue);
      expect(textOf(reply), 'Error: $kMcpAppNotRunning');
    });

    test(
      'a daemon started before any app lists the cached catalogue',
      () async {
        await connectApp();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final fresh = McpToolRelay(cachePath: paths.mcpToolsPath);
        expect([for (final t in fresh.catalogue()) t['name']], ['echo']);
      },
    );

    test(
      'a call in flight when the app goes away fails, it does not hang',
      () async {
        final (client, host) = PipeEnd.pair();
        unawaited(server.serveConnection(host));
        final watch = await HostLifecycleWatch.over(client, clientId: 'app');
        watch.offerMcpTools([_echo]);
        final called = Completer<void>();
        watch.mcpCalls.listen((_) => called.complete());
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final answer = relay.call('echo', const {}, 's1');
        await called.future;
        await watch.close();
        await expectLater(answer, throwsA(isA<McpToolRelayFailure>()));
      },
    );
  });

  group('the bridge', () {
    test(
      '/rpc over the owner-only socket is forwarded, and checks its token',
      () async {
        final mcp = await start();
        await connectApp();
        final socket = mcp.socketPath!;
        final answer =
            jsonDecode(
                  await LocalRpcClient.call(
                    socket,
                    jsonEncode({
                      'tool': 'echo',
                      'arguments': {'x': 1},
                      'token': mcp.credentials.rpcToken,
                      'callerSessionId': 's2',
                    }),
                  ),
                )
                as Map<String, Object?>;
        expect(answer['ok'], isTrue);
        expect((answer['result']! as Map)['caller'], 's2');

        final listed =
            jsonDecode(
                  await LocalRpcClient.call(
                    socket,
                    jsonEncode({
                      'tool': '__list_tools__',
                      'token': mcp.credentials.rpcToken,
                    }),
                  ),
                )
                as Map<String, Object?>;
        expect(
          [for (final t in listed['result']! as List) (t as Map)['name']],
          ['echo'],
        );

        final refused =
            jsonDecode(
                  await LocalRpcClient.call(
                    socket,
                    jsonEncode({'tool': 'echo', 'token': 'wrong'}),
                  ),
                )
                as Map<String, Object?>;
        expect(refused, {'ok': false, 'error': 'Unauthorized.'});
      },
    );
  });

  group('the handshake', () {
    test(
      'is written owner-only in the data directory, and removed on close',
      () async {
        final mcp = await start();
        final file = File(p.join(dataDir, McpBridgeHandshake.fileName));
        final handshake = McpBridgeHandshake.read(file.path)!;
        expect(handshake.port, mcp.endpoint.port);
        expect(handshake.token, mcp.credentials.rpcToken);
        expect(handshake.mcpToken, mcp.credentials.mcpToken);
        expect(handshake.socketPath, mcp.socketPath);
        if (!Platform.isWindows) {
          expect(file.statSync().mode & 0x1ff, 0x180, reason: 'rw------- only');
          final credentials = File(paths.mcpCredentialsPath).statSync();
          expect(credentials.mode & 0x1ff, 0x180);
        }
        await mcp.close();
        daemon = null;
        expect(file.existsSync(), isFalse);
      },
    );

    test('that cannot be made owner-only carries no credential, and no token '
        'is honoured', () async {
      final mcp = await start(permissions: const _Refusing());
      final handshake = McpBridgeHandshake.read(
        p.join(dataDir, McpBridgeHandshake.fileName),
      )!;
      expect(handshake.token, isNull);
      expect(handshake.mcpToken, isNull);
      expect(mcp.serving, isFalse);
      final token = mcp.credentials.callerKey.tokenFor('s1');
      expect((await rpc(mcp, token, 'ping')).$1, 401);
    });
  });
}
