import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:test/test.dart';

void main() {
  final clock = DateTime.utc(2026, 9, 25, 10, 0);
  late HookServer server;
  late List<AgentHookEvent> received;

  setUp(() async {
    received = [];
    server = await HookServer.bind(onHook: received.add, clock: () => clock);
  });

  tearDown(() => server.close());

  /// What the installed hook script sends: the probe without a token, then the
  /// payload with the token and the pane's session id.
  Future<(int, String)> send({
    String method = 'POST',
    String? token,
    String? pane,
    String body = '{"session_id":"c1","hook_event_name":"Stop"}',
    String path =
        '/agent-hook?agent=claude-code&marker=karmashala-agent-hook&event=Stop',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (pane != null) request.headers.set(kHookSessionHeader, pane);
      if (method == 'POST') request.write(body);
      final response = await request.close();
      return (response.statusCode, await utf8.decodeStream(response));
    } finally {
      client.close();
    }
  }

  test('a hook with the token is taken, with its agent, event, pane and '
      'body', () async {
    final (status, answer) = await send(token: server.token, pane: 'pane-7');
    expect(status, HttpStatus.ok);
    expect(jsonDecode(answer), {'ok': true});
    final hook = received.single;
    expect(hook.agent, 'claude-code');
    expect(hook.event, 'Stop');
    expect(hook.sessionHeader, 'pane-7');
    expect(hook.receivedAt, clock);
    expect(hook.body, {'session_id': 'c1', 'hook_event_name': 'Stop'});
  });

  test(
    'an empty pane header, as the script sends outside a pane, is none',
    () async {
      await send(token: server.token, pane: '');
      expect(received.single.sessionHeader, isNull);
    },
  );

  test(
    'a bad token or none is 401 — the probe the script makes first',
    () async {
      expect((await send(token: 'wrong')).$1, HttpStatus.unauthorized);
      expect((await send(method: 'GET')).$1, HttpStatus.unauthorized);
      expect(received, isEmpty);
    },
  );

  test(
    'a body that is not a JSON object is answered and not relayed',
    () async {
      expect((await send(token: server.token, body: 'nope')).$1, HttpStatus.ok);
      expect(received, isEmpty);
    },
  );

  test('anything but POST on the route, or another path, is 404', () async {
    expect(
      (await send(method: 'GET', token: server.token)).$1,
      HttpStatus.notFound,
    );
    expect(
      (await send(token: server.token, path: '/rpc')).$1,
      HttpStatus.notFound,
    );
  });

  test('a body over the limit is refused, and not relayed', () async {
    final big = '{"x":"${'a' * kHookPayloadLimitBytes}"}';
    try {
      final (status, _) = await send(token: server.token, body: big);
      expect(status, HttpStatus.internalServerError);
    } on HttpException {
      // Refused before the upload finished, so the connection went first.
    }
    expect(received, isEmpty);
  });

  test('a taken port falls back to a free one, keeping the token', () async {
    final second = await HookServer.bind(
      onHook: (_) {},
      port: server.port,
      token: server.token,
    );
    addTearDown(second.close);
    expect(second.port, isNot(server.port));
    expect(second.token, server.token);
  });

  group('the endpoint file', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('karmashala-hook'));
    tearDown(() => root.deleteSync(recursive: true));

    test('is written owner-only and read back', () async {
      final path = HostPaths(root).hookEndpointPath;
      await server.endpoint.write(path);

      final text = File(path).readAsStringSync();
      expect(text, contains('url=http://127.0.0.1:${server.port}/agent-hook'));
      expect(text, contains('token=${server.token}'));
      final read = HookEndpoint.read(path)!;
      expect(read.port, server.port);
      expect(read.token, server.token);
      if (!Platform.isWindows) {
        expect(File(path).statSync().modeString(), 'rw-------');
      }
    });

    test('a missing or garbled file reads as none', () {
      final path = HostPaths(root).hookEndpointPath;
      expect(HookEndpoint.read(path), isNull);
      File(path).writeAsStringSync('url=nothing\n');
      expect(HookEndpoint.read(path), isNull);
    });
  });
}
