import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/mcp/host_session_mcp.dart';
import 'package:karmashala/src/features/mcp/session_mcp.dart';
import 'package:karmashala_host/lifecycle_client.dart' show McpCredentials;
import 'package:karmashala_mcp/protocol.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';

/// With a session host, a launch is pointed at the host's endpoint with a
/// token the host's caller key issued — so it outlives this app.
void main() {
  late Directory root;
  late String handshakePath;
  late String credentialsPath;
  late McpCredentials credentials;
  late HostSessionMcp mcp;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('host-session-mcp');
    addTearDown(() => root.deleteSync(recursive: true));
    handshakePath = p.join(root.path, McpBridgeHandshake.fileName);
    credentialsPath = p.join(root.path, 'mcp.credentials');
    credentials = McpCredentials.generate().withPort(51234);
    await credentials.write(credentialsPath);
    final configs = Directory(p.join(root.path, 'mcp'))..createSync();
    mcp = HostSessionMcp(
      handshakePath: handshakePath,
      credentialsPath: credentialsPath,
      configs: SessionMcpConfigs(configs),
      bridgeExecutable: () => null,
    );
  });

  void publish({bool withCredentials = true}) =>
      File(handshakePath).writeAsStringSync(
        McpBridgeHandshake(
          port: 51234,
          pid: 1,
          token: withCredentials ? credentials.rpcToken : null,
          mcpToken: withCredentials ? credentials.mcpToken : null,
        ).encode(),
      );

  test('the config written at launch dials the host with a host-issued '
      'token for this session', () {
    publish();
    final access = mcp.accessFor(
      sessionId: 's1',
      environment: windowsEnv(),
      withConfigFile: true,
    )!;
    final config =
        jsonDecode(File(access.configPath!).readAsStringSync()) as Map;
    final entry = (config['mcpServers'] as Map)['karmashala'] as Map;
    final url = entry['url'] as String;
    expect(url, startsWith('http://127.0.0.1:51234/mcp/'));
    expect(access.url, url);
    final token = Uri.parse(url).pathSegments.last;
    // The host checks it with the same key it keeps in its own directory.
    final kept = McpCredentials.read(credentialsPath)!;
    expect(kept.callerKey.sessionFor(token), 's1');
    expect(mcp.serving, isTrue);
  });

  test('an agent that takes the URL directly gets the same URL, no file', () {
    publish();
    final access = mcp.accessFor(
      sessionId: 's1',
      environment: windowsEnv(),
      withConfigFile: false,
    )!;
    expect(access.configPath, isNull);
    expect(
      access.url,
      'http://127.0.0.1:51234/mcp/${credentials.callerKey.tokenFor('s1')}',
    );
  });

  test('nothing is handed out before the host publishes, or when it withheld '
      'its credentials', () {
    expect(
      mcp.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: true,
      ),
      isNull,
    );
    publish(withCredentials: false);
    expect(mcp.serving, isFalse);
    expect(
      mcp.accessFor(
        sessionId: 's1',
        environment: windowsEnv(),
        withConfigFile: false,
      ),
      isNull,
    );
  });
}
