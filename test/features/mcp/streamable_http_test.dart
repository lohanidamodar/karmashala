import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The Streamable HTTP transport, driven over a real socket.
///
/// The point of every case here is that **nothing carries between calls**. Each
/// request stands alone: no session id is minted, none is required, and a
/// client that vanished mid-turn is indistinguishable from one that never
/// called. That is the property agent processes need, because they die and
/// restart constantly, and it is the property a test can only prove by never
/// letting one request set up the next.
void main() {
  late Directory tmp;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_mcp_http_');
    final db = AppDatabase.memory();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(FixedClock(testTime)),
        databaseProvider.overrideWithValue(db),
      ],
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
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> handshake() =>
      jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
          as Map<String, Object?>;

  int port() => handshake()['port']! as int;
  String mcpToken() => handshake()['mcpToken']! as String;

  /// One HTTP round trip against the MCP endpoint.
  Future<({int status, Object? body, String? sessionHeader, String? allow})>
  call(
    Object? message, {
    String? credential,
    String method = 'POST',
    String path = McpHttpEndpoint.path,
    Map<String, String> headers = const <String, String>{},
    bool bearer = false,
  }) async {
    final client = HttpClient();
    try {
      final token = credential ?? mcpToken();
      final uri = Uri.parse(
        'http://127.0.0.1:${port()}$path'
        '${bearer || token.isEmpty ? '' : '/$token'}',
      );
      final request = await client.openUrl(method, uri);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/json, text/event-stream',
      );
      if (bearer && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      headers.forEach(request.headers.set);
      if (message != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(message));
      }
      final response = await request.close();
      final raw = await response.transform(utf8.decoder).join();
      return (
        status: response.statusCode,
        body: raw.isEmpty ? null : jsonDecode(raw),
        sessionHeader: response.headers.value('mcp-session-id'),
        allow: response.headers.value('allow'),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// A `2025-06-18` request: a handshake happened, no per-request metadata.
  Map<String, Object?> legacy(String method, [Map<String, Object?>? params]) =>
      <String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': method,
        'params': ?params,
      };

  /// A `2026-07-28` request plus the headers that revision requires. Kept
  /// together because the spec requires them to agree, and a helper that could
  /// build one without the other would make the mismatch tests accidental.
  ({Map<String, Object?> body, Map<String, String> headers}) modern(
    String method, [
    Map<String, Object?>? params,
  ]) {
    final merged = <String, Object?>{
      ...?params,
      '_meta': <String, Object?>{
        'io.modelcontextprotocol/protocolVersion': kMcpModernVersion,
        'io.modelcontextprotocol/clientInfo': <String, Object?>{
          'name': 'test',
          'version': '1.0.0',
        },
        'io.modelcontextprotocol/clientCapabilities': <String, Object?>{},
      },
    };
    final name = merged['name'] ?? merged['uri'];
    return (
      body: <String, Object?>{
        'jsonrpc': '2.0',
        'id': 7,
        'method': method,
        'params': merged,
      },
      headers: <String, String>{
        'MCP-Protocol-Version': kMcpModernVersion,
        'Mcp-Method': method,
        if (name is String) 'Mcp-Name': name,
      },
    );
  }

  Map<String, Object?> resultOf(Object? body) =>
      (body! as Map<String, Object?>)['result']! as Map<String, Object?>;
  Map<String, Object?> errorOf(Object? body) =>
      (body! as Map<String, Object?>)['error']! as Map<String, Object?>;

  group('the endpoint is published and gated', () {
    test('the handshake carries an MCP token and the endpoint URL', () {
      final json = handshake();
      expect(json['mcpToken'], isA<String>());
      expect(json['mcpUrl'], 'http://127.0.0.1:${json['port']}/mcp');
      // A different secret from the two that were already there. One leaked
      // credential must not be three.
      expect(json['mcpToken'], isNot(json['token']));
      expect(json['mcpToken'], isNot(json['hookToken']));
    });

    test('an unauthenticated call is refused', () async {
      expect((await call(legacy('ping'), credential: '')).status, 401);
    });

    test('a wrong token is refused', () async {
      final response = await call(legacy('ping'), credential: 'not-the-token');
      expect(response.status, 401);
    });

    test('the token may arrive as a bearer header instead', () async {
      final response = await call(legacy('ping'), bearer: true);
      expect(response.status, 200);
    });

    test('a browser origin is refused before the token is even read', () async {
      final response = await call(
        legacy('ping'),
        credential: 'not-the-token',
        headers: const {'Origin': 'https://evil.example'},
      );
      // 403 and not 401: a rebinding attempt must not learn whether its guess
      // at the token was close.
      expect(response.status, 403);
    });

    test('an opaque origin is refused', () async {
      final response = await call(
        legacy('ping'),
        headers: const {'Origin': 'null'},
      );
      expect(response.status, 403);
    });

    test('a loopback origin is allowed', () async {
      final response = await call(
        legacy('ping'),
        headers: const {'Origin': 'http://127.0.0.1:5173'},
      );
      expect(response.status, 200);
    });
  });

  group('statelessness', () {
    test('initialize mints no session id', () async {
      final response = await call(
        legacy('initialize', {'protocolVersion': '2025-06-18'}),
      );
      expect(response.status, 200);
      expect(
        response.sessionHeader,
        isNull,
        reason: 'a session id is the one thing this server must never create',
      );
    });

    test('a tool call works with no initialize before it', () async {
      // The whole point: the second request does not depend on the first, so
      // there is no first.
      final response = await call(
        legacy('tools/call', {
          'name': 'list_projects',
          'arguments': <String, Object?>{},
        }),
      );
      expect(response.status, 200);
      expect(resultOf(response.body)['isError'], isFalse);
    });

    test(
      'an Mcp-Session-Id sent by a client is ignored, not rejected',
      () async {
        final response = await call(
          legacy('ping'),
          headers: const {
            'Mcp-Session-Id': 'a-session-this-server-never-issued',
          },
        );
        expect(response.status, 200);
        expect(response.sessionHeader, isNull);
      },
    );

    test('GET is not a stream endpoint', () async {
      final response = await call(null, method: 'GET');
      expect(response.status, 405);
      expect(response.allow, 'POST');
    });

    test('DELETE cannot end a session that does not exist', () async {
      expect((await call(null, method: 'DELETE')).status, 405);
    });
  });

  group('the legacy era', () {
    test('initialize echoes a version we speak', () async {
      final response = await call(
        legacy('initialize', {'protocolVersion': '2025-06-18'}),
      );
      final result = resultOf(response.body);
      expect(result['protocolVersion'], '2025-06-18');
      expect(
        result['capabilities'],
        containsPair('tools', isA<Map<Object?, Object?>>()),
      );
      expect(
        (result['serverInfo']! as Map<String, Object?>)['name'],
        'karmashala',
      );
      expect(result['instructions'], isA<String>());
      // `resultType` arrived with the modern revision; a legacy client's schema
      // has no field for it.
      expect(result.containsKey('resultType'), isFalse);
    });

    test(
      'initialize with a version we do not speak answers with one we do',
      () async {
        final response = await call(
          legacy('initialize', {'protocolVersion': '2019-01-01'}),
        );
        final result = resultOf(response.body);
        expect(result['protocolVersion'], kMcpNewestLegacyVersion);
        // Never the modern revision: it has no handshake for this client to use.
        expect(result['protocolVersion'], isNot(kMcpModernVersion));
      },
    );

    test('notifications/initialized gets 202 and no body', () async {
      final response = await call(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(response.status, 202);
      expect(response.body, isNull);
    });

    test('tools/list serves every tool, each with annotations', () async {
      final response = await call(legacy('tools/list'));
      final tools = resultOf(response.body)['tools']! as List<Object?>;
      expect(tools, hasLength(LauncherControlServer.toolSchemas.length));
      for (final tool in tools.cast<Map<String, Object?>>()) {
        expect(
          tool['annotations'],
          isA<Map<Object?, Object?>>(),
          reason: '${tool['name']} must say what it does to the app',
        );
        expect(tool['inputSchema'], isA<Map<Object?, Object?>>());
      }
    });

    test('a request that declares nothing at all is still served', () async {
      // The pre-header revisions sent no version anywhere. The spec's fallback
      // is 2025-03-26, and the practical requirement is that it works.
      final response = await call(legacy('tools/list'));
      expect(response.status, 200);
      expect(resultOf(response.body).containsKey('resultType'), isFalse);
    });
  });

  group('the modern era', () {
    test('server/discover names the versions and the server', () async {
      final request = modern('server/discover');
      final response = await call(request.body, headers: request.headers);
      final result = resultOf(response.body);
      expect(result['resultType'], 'complete');
      expect(result['supportedVersions'], kMcpAdvertisedVersions);
      expect(
        ((result['_meta']!
                as Map<String, Object?>)['io.modelcontextprotocol/serverInfo']!
            as Map<String, Object?>)['name'],
        'karmashala',
      );
    });

    test('discovery does not advertise the modern revision', () async {
      // Claude Code 2.1.251 reads this field, picks 2026-07-28, completes
      // `server/discover` and `tools/list` against this server — and then
      // registers **no tools at all**. Measured against a real CLI and
      // reproduced against a hand-written server serving one trivial tool, so
      // it is the client's modern path and not this catalogue. Advertising a
      // revision that leaves the agent with an empty tool surface is worse than
      // not advertising it: the session looks connected and can do nothing.
      final request = modern('server/discover');
      final response = await call(request.body, headers: request.headers);

      expect(
        resultOf(response.body)['supportedVersions'],
        isNot(contains(kMcpModernVersion)),
      );
    });

    test('a client that declares the modern revision anyway is served', () async {
      // Not advertised is not unimplemented. Everything above this line in this
      // group is a modern request, and each one is answered.
      final request = modern('tools/list');
      final response = await call(request.body, headers: request.headers);

      expect(response.status, 200);
      expect(resultOf(response.body)['resultType'], 'complete');
      expect(resultOf(response.body)['tools'], isNotEmpty);
    });

    test(
      'the versions that are advertised are all versions we serve',
      () async {
        expect(kMcpSupportedVersions, containsAll(kMcpAdvertisedVersions));
      },
    );

    test('a tool call carries resultType', () async {
      final request = modern('tools/call', {
        'name': 'list_projects',
        'arguments': <String, Object?>{},
      });
      final response = await call(request.body, headers: request.headers);
      expect(resultOf(response.body)['resultType'], 'complete');
    });

    test('initialize is not a method this revision has', () async {
      final request = modern('initialize');
      final response = await call(request.body, headers: request.headers);
      expect(response.status, 404);
      expect(errorOf(response.body)['code'], McpErrorCode.methodNotFound);
    });

    test('a Mcp-Name that disagrees with the body is refused', () async {
      final request = modern('tools/call', {
        'name': 'list_projects',
        'arguments': <String, Object?>{},
      });
      final response = await call(
        request.body,
        headers: {...request.headers, 'Mcp-Name': 'list_sessions'},
      );
      expect(response.status, 400);
      expect(errorOf(response.body)['code'], McpErrorCode.headerMismatch);
    });

    test('a base64-encoded Mcp-Name is decoded before comparing', () async {
      final request = modern('tools/call', {
        'name': 'list_projects',
        'arguments': <String, Object?>{},
      });
      final encoded = base64.encode(utf8.encode('list_projects'));
      final response = await call(
        request.body,
        headers: {...request.headers, 'Mcp-Name': '=?base64?$encoded?='},
      );
      expect(response.status, 200);
    });

    test('a missing MCP-Protocol-Version header is refused', () async {
      final request = modern('tools/list');
      final headers = {...request.headers}..remove('MCP-Protocol-Version');
      final response = await call(request.body, headers: headers);
      expect(response.status, 400);
      expect(errorOf(response.body)['code'], McpErrorCode.headerMismatch);
    });

    test('a missing Mcp-Method header is refused', () async {
      final request = modern('tools/list');
      final headers = {...request.headers}..remove('Mcp-Method');
      final response = await call(request.body, headers: headers);
      expect(response.status, 400);
      expect(errorOf(response.body)['code'], McpErrorCode.headerMismatch);
    });

    test(
      'a header and body that disagree on the version are refused',
      () async {
        final request = modern('tools/list');
        final response = await call(
          request.body,
          headers: {...request.headers, 'MCP-Protocol-Version': '2025-11-25'},
        );
        expect(response.status, 400);
        expect(errorOf(response.body)['code'], McpErrorCode.headerMismatch);
      },
    );
  });

  group('version negotiation', () {
    test(
      'an unknown version is refused and the supported ones listed',
      () async {
        final response = await call(
          legacy('tools/list'),
          headers: const {'MCP-Protocol-Version': '1999-01-01'},
        );
        expect(response.status, 400);
        final error = errorOf(response.body);
        expect(error['code'], McpErrorCode.unsupportedProtocolVersion);
        final data = error['data']! as Map<String, Object?>;
        expect(data['supported'], kMcpSupportedVersions);
        expect(data['requested'], '1999-01-01');
      },
    );
  });

  group('errors', () {
    test(
      'a failing tool answers with isError, never an empty success',
      () async {
        final response = await call(
          legacy('tools/call', {
            'name': 'open_session',
            'arguments': <String, Object?>{'id': 'no-such-session'},
          }),
        );
        expect(response.status, 200);
        final result = resultOf(response.body);
        expect(result['isError'], isTrue);
        final content =
            (result['content']! as List<Object?>).first as Map<String, Object?>;
        expect(content['text'], contains('no-such-session'));
      },
    );

    test('an unknown tool is a protocol error, not a tool result', () async {
      final response = await call(
        legacy('tools/call', {
          'name': 'no_such_tool',
          'arguments': <String, Object?>{},
        }),
      );
      expect(errorOf(response.body)['code'], McpErrorCode.invalidParams);
    });

    test('an unknown method is reported as one', () async {
      final response = await call(legacy('resources/list'));
      expect(errorOf(response.body)['code'], McpErrorCode.methodNotFound);
    });

    test('malformed JSON does not take the connection down', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${port()}/mcp/${mcpToken()}'),
      );
      request.headers.contentType = ContentType.json;
      request.write('{not json');
      final response = await request.close();
      final body = jsonDecode(await response.transform(utf8.decoder).join());
      expect(response.statusCode, 400);
      expect(
        (body as Map<String, Object?>)['error'],
        isA<Map<Object?, Object?>>(),
      );

      // And the next request is unaffected, because there was nothing to break.
      expect((await call(legacy('ping'))).status, 200);
    });
  });

  group('fail closed', () {
    test('no MCP credential is published when hardening fails', () async {
      final other = Directory.systemTemp.createTempSync(
        'karmashala_mcp_closed_',
      );
      addTearDown(() {
        if (other.existsSync()) other.deleteSync(recursive: true);
      });
      final closedDb = AppDatabase.memory();
      addTearDown(closedDb.close);
      final closedContainer = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(FixedClock(testTime)),
          databaseProvider.overrideWithValue(closedDb),
        ],
      );
      final closed = LauncherControlServer(
        closedContainer,
        permissions: _RefusingPermissions(),
      );
      await closed.start(
        bridgeFilePath: p.join(other.path, 'mcp_bridge.json'),
        socketDirectory: p.join(other.path, 'ipc'),
      );
      addTearDown(() async {
        await closed.stop();
        closedContainer.dispose();
      });

      final json =
          jsonDecode(
                File(p.join(other.path, 'mcp_bridge.json')).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(
        json.containsKey('mcpToken'),
        isFalse,
        reason: 'the MCP endpoint is gated on the same hardening as /rpc',
      );
      expect(json.containsKey('mcpUrl'), isFalse);

      // And the route itself refuses everything, rather than serving unguarded.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${json['port']}/mcp'),
      );
      request.write(jsonEncode(<String, Object?>{'method': 'ping', 'id': 1}));
      final response = await request.close();
      await response.drain<void>();
      expect(response.statusCode, 401);
    });
  });
}

/// Every hardening step refuses, so nothing privileged is ever minted.
class _RefusingPermissions extends HandshakePermissions {
  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      false;

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async => false;
}
