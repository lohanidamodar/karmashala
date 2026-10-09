/// How a launched session reaches Karmashala's tools. A WSL session is given
/// the stdio bridge over interop, not the switch URL that resets on some
/// machines (PROJECT.md §18). In-process on temp directories.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_acp/karmashala_acp.dart' show McpServerStdio;
import 'package:karmashala_acp/testing.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/mcp/tools/server_tools.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../acp/acp_fixture.dart';

const _bridge = r'C:\Program Files\Karmashala\karmashala_mcp.exe';
const _bridgeInWsl = '/mnt/c/Program Files/Karmashala/karmashala_mcp.exe';

void main() {
  late Directory root;
  late DaemonMcp daemon;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('kh-mcp-access');
    final paths = HostPaths(Directory(p.join(root.path, 'host')))
      ..ensureDirectory();
    final data = Directory(p.join(root.path, 'data'))..createSync();
    daemon = await DaemonMcp.start(
      paths: paths,
      dataDirectory: data.path,
      relay: McpToolRelay(tools: ServerTools(const [])),
      preferredPort: 0,
      // No switch: the machine §18 describes, or one whose switch is down.
      wslHostAddress: () async => null,
    );
  });

  tearDown(() async {
    await daemon.close();
    root.deleteSync(recursive: true);
  });

  SessionMcpAccessPoint point({File? bridge}) => SessionMcpAccessPoint(
    mcp: daemon,
    configDirectory: p.join(root.path, 'data', 'mcp'),
    bridgeExecutable: () => bridge,
  );

  test('a WSL session gets the bridge, naming its session and the '
      'handshake in WSLENV, with no switch to dial', () {
    final access = point(
      bridge: File(_bridge),
    ).accessFor('s1', withConfigFile: false, kind: EnvironmentKind.wsl);
    expect(access, isNotNull);
    expect(access!.url, isNull);
    expect(access.bridge!.command, _bridgeInWsl);
    expect(access.bridge!.environment, {
      'KARMASHALA_SESSION_ID': 's1',
      'KARMASHALA_BRIDGE_HANDSHAKE': daemon.handshakePath,
      'WSLENV': 'KARMASHALA_SESSION_ID/u:KARMASHALA_BRIDGE_HANDSHAKE/u',
    });
  });

  test('a config-file agent in WSL is pointed at a file that spawns the '
      'bridge and holds no token', () {
    final access = point(
      bridge: File(_bridge),
    ).accessFor('s1', withConfigFile: true, kind: EnvironmentKind.wsl);
    expect(access, isNotNull);
    final hostPath = p.join(root.path, 'data', 'mcp', 'session-s1.json');
    final written = File(hostPath).readAsStringSync();
    final entry =
        ((jsonDecode(written) as Map)['mcpServers'] as Map)['karmashala']
            as Map;
    expect(entry['type'], 'stdio');
    expect(entry['command'], _bridgeInWsl);
    expect((entry['env'] as Map)['KARMASHALA_SESSION_ID'], 's1');
    expect(
      written,
      isNot(contains(daemon.credentials.callerKey.tokenFor('s1'))),
    );
  }, testOn: 'windows');

  test('with no bridge and no switch a WSL session is given nothing', () {
    expect(
      point().accessFor('s1', withConfigFile: false, kind: EnvironmentKind.wsl),
      isNull,
    );
  });

  test('a session on this machine keeps its loopback URL, bridge or not', () {
    final access = point(bridge: File(_bridge)).accessFor(
      's1',
      withConfigFile: false,
      kind: EnvironmentKind.windowsNative,
    );
    expect(access!.bridge, isNull);
    expect(access.url, startsWith('http://127.0.0.1:${daemon.endpoint.port}'));
  });

  test('an ACP agent is handed the bridge in session/new', () async {
    final database = AppDatabase.memory();
    addTearDown(database.close);
    final process = FakeAcpProcess(FakeAcpAgent(turns: const []));
    final runtime = runtimeOver(
      process,
      database: database,
      workingDirectory: root.path,
      mcpUrl: 'http://172.18.240.1:1/mcp/tok',
      mcpBridge: const McpServerStdio(
        'karmashala',
        command: _bridgeInWsl,
        env: {'KARMASHALA_SESSION_ID': 's1'},
      ),
    );
    final outcome = await runtime.start();
    expect(outcome.notices, isEmpty);
    expect(process.agent.newSessionParams.single['mcpServers'], [
      {
        'name': 'karmashala',
        'command': _bridgeInWsl,
        'args': <Object?>[],
        'env': [
          {'name': 'KARMASHALA_SESSION_ID', 'value': 's1'},
        ],
      },
    ]);
    await runtime.stop();
  });

  group('findMcpBridge', () {
    test('finds the exe in the Release folder above a host bundle', () {
      final release = Directory(p.join(root.path, 'Release'))..createSync();
      final bin = Directory(p.join(release.path, 'host', 'bin'))
        ..createSync(recursive: true);
      File(p.join(release.path, 'karmashala_mcp.exe')).writeAsStringSync('');
      expect(
        findMcpBridge(
          executable: p.join(bin.path, 'karmashala_host.exe'),
          environment: const {},
        )?.path,
        p.join(release.path, 'karmashala_mcp.exe'),
      );
      expect(
        findMcpBridge(
          executable: p.join(root.path, 'elsewhere', 'dart.exe'),
          environment: const {},
        ),
        isNull,
      );
    });
  }, testOn: 'windows');
}
