import 'dart:convert';
import 'dart:io';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_hook_receiver.dart';
import 'package:karmashala/src/features/agents/domain/agent_hook_endpoint.dart';
import 'package:karmashala/src/features/agents/domain/agent_status.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The `/agent-hook` route on the launcher control server.
///
/// Loop 28 shipped this endpoint as a second `HttpServer` because
/// `launcher_control_server.dart` belonged to another branch at the time; Loop
/// 31 collapsed it onto the route it always wanted to be. These are the same
/// assertions the standalone server had, retargeted.
void main() {
  late Directory tmp;
  late ProviderContainer container;
  late AgentHookReports reports;
  late LauncherControlServer server;
  late AgentHookEndpoint endpoint;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_hooks_');
    container = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(FixedClock(testTime))],
    );
    reports = container.read(agentHookReportsProvider);
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      useLocalSocket: false,
      // A port of this file's own. The production default is one fixed port,
      // because the Hyper-V rule that lets WSL agents in has to name it — but
      // that makes it a port every test file in the run would share, and
      // "stop() closes the port" then observed somebody else's server still
      // listening on it.
      preferredPort: await _freePort(),
    );
    endpoint = server.hookEndpoint!;
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
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
      endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Stop',
        environment: EnvironmentKind.windowsNative,
      )!.host,
      '127.0.0.1',
    );
  });

  test('the handshake file carries the hook token', () async {
    final file = File(p.join(tmp.path, 'mcp_bridge.json'));
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['port'], endpoint.port);
    expect(json['hookToken'], endpoint.token);
    // The hook token is deliberately *not* the /rpc token: it is pasted into an
    // agent's config file and shows up in process command lines, while /rpc can
    // open sessions and drive devices.
    expect(json['token'], isNot(endpoint.token));
  });

  test('an authenticated callback reaches the receiver', () async {
    final response = await post(
      endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Stop',
        environment: EnvironmentKind.windowsNative,
      )!,
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
      endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Whatever',
        environment: EnvironmentKind.windowsNative,
      )!,
      token: endpoint.token,
    );

    // 200 on purpose: a hook must never block the agent that fired it.
    expect(response.statusCode, HttpStatus.ok);
    expect(reports.latest('claudeCode', 's1'), isNull);
  });

  test('a wrong token is rejected and records nothing', () async {
    final response = await post(
      endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Stop',
        environment: EnvironmentKind.windowsNative,
      )!,
      token: 'not-the-token',
    );

    expect(response.statusCode, HttpStatus.unauthorized);
    expect(reports.latest('claudeCode', 's1'), isNull);
  });

  test('a missing token is rejected', () async {
    final response = await post(
      endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Stop',
        environment: EnvironmentKind.windowsNative,
      )!,
    );

    expect(response.statusCode, HttpStatus.unauthorized);
  });

  test('the hook token does not open /rpc', () async {
    final response = await post(
      Uri.parse('http://127.0.0.1:${endpoint.port}/rpc'),
      token: endpoint.token,
      body: jsonEncode({'tool': '__list_tools__'}),
    );

    expect(response.statusCode, HttpStatus.unauthorized);
  });

  test('the wrong method on the hook route is a 404', () async {
    final response = await post(
      endpoint.uriFor(
        agentId: 'claudeCode',
        event: 'Stop',
        environment: EnvironmentKind.windowsNative,
      )!,
      token: endpoint.token,
      method: 'GET',
    );

    expect(response.statusCode, HttpStatus.notFound);
  });

  test('stop() closes the port', () async {
    final port = endpoint.port;
    await server.stop();

    expect(server.hookEndpoint, isNull);
    await expectLater(
      post(Uri.parse('http://127.0.0.1:$port/agent-hook'), token: 'x'),
      throwsA(isA<SocketException>()),
    );
  });
}

/// A port nothing is listening on: bound to learn its number, then released.
Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}
