/// The launch tools' schemas reach an agent unchanged by every way it can
/// list them: the server's `/mcp`, the `/rpc` socket, and the stdio bridge
/// in front of that socket. The app serves no tools of its own.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/mcp_tools.dart' show serverToolSchemas;
import 'package:karmashala_host/src/mcp/tools/launch_tool_set.dart'
    show launchToolSchemas;
import 'package:karmashala_host/src/mcp/tools/server_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tools.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:karmashala_mcp/catalogue.dart' show annotatedToolSchemas;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The whole served catalogue, so annotation merging runs as it does live.
class _Catalogue extends ServerToolSet {
  @override
  List<Map<String, Object?>> get schemas => serverToolSchemas;

  @override
  Future<Object?>? call(String tool, Map<String, dynamic> a, String? c) =>
      null;
}

void main() {
  late Directory root;
  late DaemonMcp mcp;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('kh-schema-paths');
    final paths = HostPaths(Directory(p.join(root.path, 'host')))
      ..ensureDirectory();
    final dataDir = p.join(root.path, 'data');
    Directory(dataDir).createSync();
    mcp = await DaemonMcp.start(
      paths: paths,
      dataDirectory: dataDir,
      relay: McpToolRelay(tools: ServerTools([_Catalogue()])),
      preferredPort: 0,
    );
  });

  tearDown(() async {
    await mcp.close();
    root.deleteSync(recursive: true);
  });

  /// [served]'s launch tools, JSON-normalised.
  List<Object?> launchToolsIn(List<Object?> served) {
    final names = {for (final s in launchToolSchemas) s['name']};
    return jsonDecode(
          jsonEncode([
            for (final tool in served)
              if (names.contains((tool! as Map)['name'])) tool,
          ]),
        )
        as List<Object?>;
  }

  final expected = jsonDecode(
    jsonEncode(annotatedToolSchemas(launchToolSchemas)),
  );

  test("/mcp's tools/list carries launchToolSchemas as written", () async {
    final client = HttpClient();
    final token = mcp.credentials.callerKey.tokenFor('s1');
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${mcp.endpoint.port}/mcp/$token'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
      );
      final response = await request.close();
      final body =
          jsonDecode(await response.transform(utf8.decoder).join())
              as Map<String, Object?>;
      final tools = (body['result']! as Map)['tools']! as List<Object?>;
      expect(launchToolsIn(tools), expected);
    } finally {
      client.close(force: true);
    }
  });

  test("/rpc's __list_tools__ carries launchToolSchemas as written", () async {
    final answer =
        jsonDecode(
              await LocalRpcClient.call(
                mcp.socketPath!,
                jsonEncode({
                  'tool': '__list_tools__',
                  'token': mcp.credentials.rpcToken,
                }),
              ),
            )
            as Map<String, Object?>;
    expect(launchToolsIn(answer['result']! as List<Object?>), expected);
  });

  test('the stdio bridge passes launchToolSchemas through as written', () async {
    // The bridge is run from source, resolved by the workspace.
    final workspace = p.normalize(p.join(Directory.current.path, '..'));
    final bridge = await Process.start(Platform.resolvedExecutable, [
      '--packages=${p.join(workspace, '.dart_tool', 'package_config.json')}',
      p.join(workspace, 'packages', 'mcp_bridge', 'bin', 'karmashala_mcp.dart'),
    ], environment: {'KARMASHALA_BRIDGE_HANDSHAKE': mcp.handshakePath});
    final lines = bridge.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    unawaited(bridge.stderr.drain<void>());
    try {
      bridge.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': 7, 'method': 'tools/list'}),
      );
      await bridge.stdin.flush();
      final reply =
          jsonDecode(await lines.first.timeout(const Duration(minutes: 2)))
              as Map<String, Object?>;
      final tools = (reply['result']! as Map)['tools']! as List<Object?>;
      expect(launchToolsIn(tools), expected);
    } finally {
      bridge.kill();
      await bridge.exitCode;
    }
  });
}
