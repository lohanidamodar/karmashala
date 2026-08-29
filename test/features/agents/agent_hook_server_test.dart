import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/features/agents/data/agent_hook_receiver.dart';
import 'package:chitragupta/src/features/agents/data/agent_hook_server.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:chitragupta/src/features/agents/domain/agent_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late Directory tmp;
  late AgentHookReports reports;
  late AgentHookServer server;
  late AgentHookEndpoint endpoint;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('chitra_hooks_');
    reports = AgentHookReports();
    server = AgentHookServer(
      AgentHookReceiver(
        registry: AgentRegistry.builtIn,
        reports: reports,
        clock: FixedClock(testTime),
      ),
    );
    endpoint = await server.start(
      handshakeFilePath: p.join(tmp.path, 'agent_hooks.json'),
    );
  });

  tearDown(() async {
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<HttpClientResponse> post(
    Uri uri, {
    String? token,
    String body = '{"session_id":"s1"}',
    String method = 'POST',
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, uri);
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (method != 'GET') request.write(body);
      return await request.close();
    } finally {
      client.close();
    }
  }

  test('binds loopback and publishes a port and token', () {
    expect(endpoint.port, greaterThan(0));
    expect(endpoint.token, isNotEmpty);
    expect(
      endpoint.uriFor(agentId: 'claudeCode', event: 'Stop').host,
      '127.0.0.1',
    );
  });

  test('writes a handshake file the hook command can read', () async {
    final file = File(p.join(tmp.path, 'agent_hooks.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['port'], endpoint.port);
    expect(json['token'], endpoint.token);
  });

  test('an authenticated callback reaches the receiver', () async {
    final response = await post(
      endpoint.uriFor(agentId: 'claudeCode', event: 'Stop'),
      token: endpoint.token,
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(
      reports.latest('claudeCode', 's1')!.status,
      AgentActivityStatus.idle,
    );
  });

  test('an unknown event is accepted but records nothing', () async {
    final response = await post(
      endpoint.uriFor(agentId: 'claudeCode', event: 'Whatever'),
      token: endpoint.token,
    );

    // 200 on purpose: a hook must never block the agent that fired it.
    expect(response.statusCode, HttpStatus.ok);
    expect(reports.latest('claudeCode', 's1'), isNull);
  });

  test('a wrong token is rejected and records nothing', () async {
    final response = await post(
      endpoint.uriFor(agentId: 'claudeCode', event: 'Stop'),
      token: 'not-the-token',
    );

    expect(response.statusCode, HttpStatus.unauthorized);
    expect(reports.latest('claudeCode', 's1'), isNull);
  });

  test('a missing token is rejected', () async {
    final response = await post(
      endpoint.uriFor(agentId: 'claudeCode', event: 'Stop'),
    );

    expect(response.statusCode, HttpStatus.unauthorized);
  });

  test('the wrong path or method is a 404', () async {
    final wrongPath = await post(
      Uri.parse('http://127.0.0.1:${endpoint.port}/rpc'),
      token: endpoint.token,
    );
    expect(wrongPath.statusCode, HttpStatus.notFound);

    final wrongMethod = await post(
      endpoint.uriFor(agentId: 'claudeCode', event: 'Stop'),
      token: endpoint.token,
      method: 'GET',
    );
    expect(wrongMethod.statusCode, HttpStatus.notFound);
  });

  test('stop() closes the port', () async {
    final port = endpoint.port;
    await server.stop();

    expect(server.endpoint, isNull);
    await expectLater(
      post(Uri.parse('http://127.0.0.1:$port/agent-hook'), token: 'x'),
      throwsA(isA<SocketException>()),
    );
  });
}
