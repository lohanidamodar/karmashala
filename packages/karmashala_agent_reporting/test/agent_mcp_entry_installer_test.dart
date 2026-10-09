import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import 'support/temp_directory.dart';

/// Karmashala's entry in agy's own `mcp_config.json`: added and updated in
/// place, removed alone, and never at the cost of the person's own servers.
void main() {
  const installer = AgentMcpEntryInstaller();
  final antigravity = AgentRegistry.builtIn.byId('antigravity')!;
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;

  late Directory home;
  late String store;
  late File config;
  setUp(() {
    home = Directory.systemTemp.createTempSync('karmashala_mcp_entry_');
    store = p.join(home.path, '.gemini', 'antigravity-cli');
    Directory(store).createSync(recursive: true);
    config = File(p.join(home.path, '.gemini', 'config', 'mcp_config.json'));
  });
  tearDown(() => removeTempDirectory(home));

  final entry = karmashalaMcpEntry(
    kind: EnvironmentKind.windowsNative,
    bridgePath: r'C:\Karmashala\karmashala_mcp.exe',
  );

  Map<String, Object?> servers() =>
      (jsonDecode(config.readAsStringSync()) as Map)['mcpServers']
          as Map<String, Object?>;

  const userFile = '''{
  "mcpServers": {
    "dart": {
      "command": "dart.exe",
      "args": [
        "mcp-server"
      ]
    }
  },
  "other": true
}
''';

  test(
    'agy declares the entry; Claude Code, with per-launch MCP, does not',
    () {
      expect(installer.fileFor(antigravity, store)!.path, config.path);
      expect(installer.fileFor(claude, store), isNull);
    },
  );

  test('the entry for each environment', () {
    expect(entry, {
      'command': r'C:\Karmashala\karmashala_mcp.exe',
      'args': ['--session-only'],
    });
    expect(
      karmashalaMcpEntry(
        kind: EnvironmentKind.wsl,
        bridgePath: '/mnt/c/Karmashala/karmashala_mcp.exe',
      ),
      {
        'command': '/usr/bin/env',
        'args': [
          'WSLENV=KARMASHALA_SESSION_ID',
          '/mnt/c/Karmashala/karmashala_mcp.exe',
          '--session-only',
        ],
      },
    );
  });

  test('adds the entry and keeps the person\'s servers and keys', () async {
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(userFile);

    final state = await installer.install(antigravity, store, entry);

    expect(state, KarmashalaMcpEntryState.current);
    expect(servers().keys, ['dart', 'karmashala']);
    expect(servers()['dart'], {
      'command': 'dart.exe',
      'args': ['mcp-server'],
    });
    expect(servers()['karmashala'], entry);
    final text = config.readAsStringSync();
    expect(text, endsWith('  "other": true\n}\n'));
    expect(text, contains('\n  "mcpServers": {\n    "dart": {\n'));
  });

  test('creates the file when agy has never written one', () async {
    expect(
      await installer.install(antigravity, store, entry),
      KarmashalaMcpEntryState.current,
    );
    expect(servers(), {'karmashala': entry});
    expect(config.readAsStringSync(), startsWith('{\n  "mcpServers": {\n'));
    expect(config.readAsStringSync(), endsWith('  }\n}\n'));
  });

  test('writes nothing when agy is not installed', () async {
    Directory(store).deleteSync(recursive: true);
    expect(
      await installer.install(antigravity, store, entry),
      KarmashalaMcpEntryState.absent,
    );
    expect(config.existsSync(), isFalse);
  });

  test('a current entry is left byte for byte; a stale one updated', () async {
    await installer.install(antigravity, store, entry);
    final written = config.lastModifiedSync();
    final bytes = config.readAsStringSync();
    expect(
      await installer.install(antigravity, store, entry),
      KarmashalaMcpEntryState.current,
    );
    expect(config.readAsStringSync(), bytes);
    expect(config.lastModifiedSync(), written);

    final moved = karmashalaMcpEntry(
      kind: EnvironmentKind.windowsNative,
      bridgePath: r'D:\Elsewhere\karmashala_mcp.exe',
    );
    expect(
      await installer.stateOf(antigravity, store, entry: moved),
      KarmashalaMcpEntryState.stale,
    );
    await installer.install(antigravity, store, moved);
    expect(servers()['karmashala'], moved);
  });

  test('remove takes out only ours', () async {
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(userFile);
    await installer.install(antigravity, store, entry);

    expect(
      await installer.remove(antigravity, store),
      KarmashalaMcpEntryState.absent,
    );
    expect(servers().keys, ['dart']);
    expect(jsonDecode(config.readAsStringSync())['other'], isTrue);
  });

  test('a karmashala entry the person wrote is never touched', () async {
    const own = {'serverUrl': 'http://127.0.0.1:9/mcp'};
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(
      jsonEncode({
        'mcpServers': {'karmashala': own},
      }),
    );
    final before = config.readAsStringSync();

    expect(
      await installer.install(antigravity, store, entry),
      KarmashalaMcpEntryState.foreign,
    );
    expect(
      await installer.remove(antigravity, store),
      KarmashalaMcpEntryState.foreign,
    );
    expect(config.readAsStringSync(), before);
  });
}
