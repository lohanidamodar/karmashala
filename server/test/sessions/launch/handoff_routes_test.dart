// Windows paths throughout: the launches are a Windows server's.
@TestOn('windows')
library;

import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/automations/hosted_agent_launcher.dart';
import 'package:karmashala_host/src/sessions/launch/session_handoffs.dart';
import 'package:karmashala_session/launch.dart' show SessionSurface;
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Each way a launch hands its agent an opening message or a packet: on the
/// command line where it arrives intact, typed in where the agent takes a
/// typed message whole, else a file in the session's own temp folder. The
/// text is a `session_handoffs` row whichever way it went, and nothing is
/// written to the data folder or the checkout.
void main() {
  final t0 = DateTime.utc(2026, 10, 4, 12);
  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher pty;
  late Directory temp;
  late Directory root;
  late SessionHandoffs handoffs;
  late List<String> pending;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('routes');
    root = Directory(p.join(temp.path, 'tmp-root'));
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      'VALUES (?, ?, ?, ?), (?, ?, ?, ?);',
      [
        'win', 'windowsNative', 'Windows', '$t0', //
        'nix', 'localPosix', 'Linux', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?);',
      [
        'r1', 'p1', 'shop', 'win', temp.path, '$t0', //
        'r2', 'p1', 'shop', 'nix', '/src/shop', '$t0',
      ],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) VALUES '
      '(?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?), '
      '(?, ?, ?, ?, ?, ?);',
      [
        'cx', AgentIds.codex, 'win', r'C:\bin\codex.exe', '$t0', 1, //
        'cc', AgentIds.claudeCode, 'win', r'C:\bin\claude.exe', '$t0', 1,
        'cx-nix', AgentIds.codex, 'nix', '/bin/codex', '$t0', 1,
        'cc-nix', AgentIds.claudeCode, 'nix', '/bin/claude', '$t0', 1,
      ],
    );
    handoffs = SessionHandoffs(
      dao: SessionHandoffDao(database),
      root: root,
      now: () => t0,
    );
    pending = [];
    handoffs.onPending = pending.add;
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

  Future<HostedStart> launch(
    String installation, {
    String? prompt,
    String? packet,
    String repository = 'r1',
    String title = 'cart',
    bool windows = true,
    SessionSurface surface = SessionSurface.pane,
  }) {
    final rows = CheckoutRows(database);
    return HostedAgentLauncher(
      registry: registry,
      sessions: SessionDao(database),
      mcp: SessionMcpAccessPoint(mcp: null, configDirectory: temp.path),
      now: () => t0,
      newId: () => 's-$installation',
      hostEnvironment: const {},
      environmentOf: rows.environment,
      handoffs: handoffs,
      windows: windows,
    ).startDetailed(
      HostedLaunch(
        repository: rows.repository(repository)!,
        installation: rows.installation(installation)!,
        title: title,
        prompt: prompt,
        systemPrompt: packet,
        surface: surface,
      ),
    );
  }

  List<String> argv() => pty.started.last.argv;
  SessionHandoff? row(String id, HandoffKind kind) =>
      SessionHandoffDao(database).get(id, kind);
  const multiLine = 'line one\nline "two" with %PATH%';

  group('an opening message', () {
    test('Claude Code on Windows has it typed in once ready: no file, no '
        'pointer', () async {
      await launch('cc', prompt: multiLine);
      expect(argv().where((a) => a.contains('line one')), isEmpty);
      expect(argv().where((a) => a.startsWith('--add-dir')), isEmpty);
      final held = row('s-cc', HandoffKind.opening)!;
      expect(held.route, HandoffRoute.typed);
      expect(held.text, multiLine);
      expect(held.consumedAt, isNull);
      expect(pending, ['s-cc']);
      expect(root.existsSync(), isFalse);
    });

    test('Codex on Windows, which nobody measured typing into, is pointed at '
        'a file in its own temp folder', () async {
      await launch('cx', prompt: multiLine);
      final folder = handoffs.folderOf('s-cx').path;
      expect(argv().last, startsWith('My opening message to you is in the '));
      expect(argv().last, contains(folder));
      expect(argv().last, isNot(contains('handoff')));
      expect(argv()[argv().indexOf('--add-dir') + 1], folder);
      expect(
        File(p.join(folder, 'message.md')).readAsStringSync(),
        multiLine.trim(),
      );
      expect(row('s-cx', HandoffKind.opening)!.route, HandoffRoute.file);
      expect(pending, ['s-cx']);
      expect(temp.listSync().whereType<File>(), isEmpty);
    });

    test(
      'one the command line carries rides there and is used at once',
      () async {
        await launch('cx', prompt: 'make the cart faster');
        expect(argv().last, 'make the cart faster');
        expect(argv(), isNot(contains('--add-dir')));
        final held = row('s-cx', HandoffKind.opening)!;
        expect(held.route, HandoffRoute.argv);
        expect(held.consumedAt, t0);
        expect(pending, isEmpty);
        expect(root.existsSync(), isFalse);
      },
    );

    test('a POSIX command line carries a multi-line one whole', () async {
      await launch(
        'cx-nix',
        prompt: multiLine,
        repository: 'r2',
        windows: false,
      );
      expect(argv(), contains(multiLine));
      expect(row('s-cx-nix', HandoffKind.opening)!.route, HandoffRoute.argv);
      expect(root.existsSync(), isFalse);
    });

    test('a terminal window nobody here reads is handed a file, not typed '
        'into', () async {
      final started = await launch(
        'cc',
        prompt: multiLine,
        surface: SessionSurface.external,
      );
      final arguments = started.external!.arguments;
      expect(arguments.last, contains(handoffs.folderOf('s-cc').path));
      expect(row('s-cc', HandoffKind.opening)!.route, HandoffRoute.file);
    });
  });

  group('the title', () {
    test('an unnamed session pointed at a file is named from the message, '
        'not the pointer', () async {
      final started = await launch(
        'cx',
        prompt: '# Speed up the cart\n\nThe totals are slow.',
        title: '',
      );
      expect(started.session.title, 'Speed up the cart');
      final saved = SessionDao(database).getById('s-cx')!;
      expect(saved.title, 'Speed up the cart');
      expect(saved.titleByUser, isFalse);
    });

    test('an unnamed session typed into waits for the agent to name it from '
        'the message it has', () async {
      final started = await launch('cc', prompt: multiLine, title: '');
      expect(started.session.title, 'Session');
    });

    test('a named session keeps its name', () async {
      final started = await launch('cx', prompt: multiLine);
      expect(started.session.title, 'cart');
    });
  });

  group('a packet', () {
    test('Claude Code on Windows takes it as a system-prompt file in the temp '
        'folder', () async {
      await launch('cc', prompt: 'Carry on.', packet: '# Brief\n\nDo it.');
      final at = argv().indexOf('--append-system-prompt-file');
      final path = argv()[at + 1];
      expect(p.isWithin(handoffs.folderOf('s-cc').path, path), isTrue);
      expect(File(path).readAsStringSync(), '# Brief\n\nDo it.');
      expect(argv().last, 'Carry on.');
      expect(row('s-cc', HandoffKind.systemPrompt)!.route, HandoffRoute.file);
    });

    test('Claude Code on POSIX takes it inline: no file at all', () async {
      await launch(
        'cc-nix',
        prompt: 'Carry on.',
        packet: '# Brief\n\nDo it.',
        repository: 'r2',
        windows: false,
      );
      final at = argv().indexOf('--append-system-prompt');
      expect(argv()[at + 1], '# Brief\n\nDo it.');
      expect(argv(), isNot(contains('--append-system-prompt-file')));
      final held = row('s-cc-nix', HandoffKind.systemPrompt)!;
      expect(held.route, HandoffRoute.argv);
      expect(held.consumedAt, t0);
      expect(root.existsSync(), isFalse);
    });

    test(
      'an agent with no system prompt is pointed at it as its brief',
      () async {
        await launch('cx', packet: '# Brief\n\nDo it.');
        expect(
          argv().last,
          startsWith('Your brief for this session is in the '),
        );
        expect(argv().last, isNot(contains('handoff')));
        final held = row('s-cx', HandoffKind.packet)!;
        expect(held.route, HandoffRoute.file);
        expect(
          File(
            p.join(handoffs.folderOf('s-cx').path, 'brief.md'),
          ).readAsStringSync(),
          '# Brief\n\nDo it.',
        );
      },
    );
  });
}
