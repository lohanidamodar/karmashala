import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/features/agents/data/agent_hook_installer.dart';
import 'package:chitragupta/src/features/agents/data/agent_hook_server.dart';
import 'package:chitragupta/src/features/agents/domain/agent_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const installer = AgentHookInstaller();
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;
  final antigravity = AgentRegistry.builtIn.byId('antigravity')!;

  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('chitra_hookcfg_');
  });
  tearDown(() => home.deleteSync(recursive: true));

  File configFile() => File(p.join(home.path, 'settings.json'));

  Map<String, dynamic> hooks() {
    final json = jsonDecode(configFile().readAsStringSync()) as Map;
    return (json['hooks'] as Map).cast<String, dynamic>();
  }

  List<Map<String, dynamic>> commandsFor(String event) => [
    for (final matcher in hooks()[event] as List)
      for (final hook in (matcher as Map)['hooks'] as List)
        (hook as Map).cast<String, dynamic>(),
  ];

  test('creates the config with one entry per declared event', () async {
    final installed = await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
    );

    expect(installed, isTrue);
    expect(hooks().keys.toSet(), claude.hooks!.eventStatus.keys.toSet());
    final stop = commandsFor('Stop').single;
    expect(stop['type'], 'command');
    expect(stop['command'], contains('127.0.0.1:4242/agent-hook'));
    expect(stop['command'], contains('agent=claudeCode'));
    expect(stop['command'], contains('event=Stop'));
    expect(stop['command'], contains('Bearer tok'));
    expect(stop['command'], contains(agentHookMarker));
  });

  test('leaves sibling keys byte-for-byte intact', () async {
    // Keys differing only by case are legal JSON that a decode/encode round
    // trip would collapse — the splice must not touch them.
    configFile().writeAsStringSync(
      '{"projects": {"g:/x": 1, "G:/x": 2}, "model": "opus"}',
    );

    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
    );

    final raw = configFile().readAsStringSync();
    expect(raw, contains('"g:/x": 1'));
    expect(raw, contains('"G:/x": 2'));
    expect(raw, contains('"model": "opus"'));
  });

  test("keeps the user's own hooks for the same event", () async {
    configFile().writeAsStringSync(
      jsonEncode({
        'hooks': {
          'Stop': [
            {
              'hooks': [
                {'type': 'command', 'command': 'mine.sh'},
              ],
            },
          ],
        },
      }),
    );

    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
    );

    final commands = commandsFor('Stop').map((h) => h['command']).toList();
    expect(commands, contains('mine.sh'));
    expect(commands.where((c) => '$c'.contains(agentHookMarker)), hasLength(1));
  });

  test('re-installing is idempotent', () async {
    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
    );
    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: const AgentHookEndpoint(port: 5555, token: 'tok2'),
    );

    final commands = commandsFor('Stop');
    expect(commands, hasLength(1));
    // The rewritten command points at the new (ephemeral) port.
    expect(commands.single['command'], contains('127.0.0.1:5555'));
  });

  test('uninstall removes only our entries', () async {
    configFile().writeAsStringSync(
      jsonEncode({
        'hooks': {
          'Stop': [
            {
              'hooks': [
                {'type': 'command', 'command': 'mine.sh'},
              ],
            },
          ],
        },
        'model': 'opus',
      }),
    );
    await installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
    );

    final removed = await installer.uninstall(
      descriptor: claude,
      storeHome: home.path,
    );

    expect(removed, isTrue);
    expect(commandsFor('Stop').map((h) => h['command']), ['mine.sh']);
    // Events we added and the user did not are dropped entirely.
    expect(hooks().containsKey('PreToolUse'), isFalse);
    expect(configFile().readAsStringSync(), contains('"model"'));
  });

  test('an agent with no hook spec installs nothing', () async {
    final installed = await installer.install(
      descriptor: antigravity,
      storeHome: home.path,
      endpoint: endpoint,
    );

    expect(installed, isFalse);
    expect(configFile().existsSync(), isFalse);
  });

  test('a malformed config is refused and left untouched', () async {
    configFile().writeAsStringSync('{ not json');

    await expectLater(
      installer.install(
        descriptor: claude,
        storeHome: home.path,
        endpoint: endpoint,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(configFile().readAsStringSync(), '{ not json');
  });

  test('uninstall on a config we never touched is a no-op', () async {
    configFile().writeAsStringSync('{"model": "opus"}');

    final removed = await installer.uninstall(
      descriptor: claude,
      storeHome: home.path,
    );

    expect(removed, isFalse);
    expect(configFile().readAsStringSync(), '{"model": "opus"}');
  });
}
