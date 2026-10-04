// A Windows-native launch: the paths the agent is handed are this host's.
@TestOn('windows')
library;

import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/handoff_packet_files.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// A prompt a Windows-native launch could not carry is written under the
/// data directory and the agent told to read it; an agent that can be granted
/// a directory at launch is granted that one, so it does not ask to read
/// outside its workspace. Nothing is written into the checkout.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);
  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late Directory temp;
  late Directory handoff;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('prompt_dir');
    handoff = Directory('${temp.path}${Platform.pathSeparator}handoff');
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?);',
      ['win', 'windowsNative', 'Windows', '$t0'],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'shop', 'win', temp.path, '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'cx', AgentIds.codex, 'win', r'C:\bin\codex.exe', '$t0', 1, //
        'cc', AgentIds.claudeCode, 'win', r'C:\bin\claude.exe', '$t0', 1,
      ],
    );
    pty = FakePtyLauncher();
    registry = SessionRegistry(launcher: pty);
  });

  tearDown(() async {
    for (final handle in pty.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  Future<List<String>> launch(String installation, String prompt) async {
    final rows = CheckoutRows(database);
    await HostedAgentLauncher(
      registry: registry,
      sessions: SessionDao(database),
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
      now: () => t0,
      newId: () => 's-$installation',
      hostEnvironment: const {},
      environmentOf: rows.environment,
      handoffFiles: HandoffPacketFiles(handoff),
      windows: true,
    ).start(
      HostedLaunch(
        repository: rows.repository('r1')!,
        installation: rows.installation(installation)!,
        title: 'cart',
        prompt: prompt,
      ),
    );
    return pty.started.last.argv;
  }

  test(
    'a prompt handed over as a file grants Codex the directory it is in',
    () async {
      final argv = await launch('cx', 'line one\nline "two"');
      final at = argv.indexOf('--add-dir');
      expect(at, isNot(-1));
      expect(argv[at + 1], handoff.path);
      expect(argv.last, contains(handoff.path));
      expect(argv.indexOf('--add-dir'), lessThan(argv.length - 1));
      // Nothing of it in the checkout.
      expect(Directory(temp.path).listSync().whereType<File>(), isEmpty);
    },
  );

  test('a prompt that rides on the command line grants nothing', () async {
    final argv = await launch('cx', 'make the cart faster');
    expect(argv, isNot(contains('--add-dir')));
    expect(argv.last, 'make the cart faster');
  });

  test('Claude Code is granted it in one entry, and its pointer stays the '
      'prompt', () async {
    final argv = await launch('cc', 'line one\nline two');
    expect(argv, contains('--add-dir=${handoff.path}'));
    expect(argv, isNot(contains('--add-dir')));
    expect(argv.last, contains(handoff.path));
    expect(argv.last, isNot(startsWith('--')));
  });

  test('Claude Code, prompt on the command line, is granted nothing', () async {
    final argv = await launch('cc', 'make the cart faster');
    expect(argv.where((a) => a.startsWith('--add-dir')), isEmpty);
  });
}
