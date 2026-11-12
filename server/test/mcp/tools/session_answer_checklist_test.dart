import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/data.dart' show DataService;
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/session_tool_set.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/daemon_prompt_answers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../../../../packages/karmashala_agent_status/test/mcp_checklist_screen.dart';

/// Claude Code's project-MCP checklist answered from `session_answer` (review
/// 2026-11-12, 3a): by its ticks, by dismiss, or by approve and deny, which
/// on a checklist enable every box or reject them all.
void main() {
  final t0 = DateTime.utc(2026, 11, 12, 12);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late ServerToolContext context;
  late SessionToolSet tools;
  late _ChecklistPane pane;

  setUp(() async {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the cart',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: t0,
      ),
    );
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      interval: const Duration(hours: 1),
    );
    final prompts = DaemonPromptAnswers(
      status: status,
      database: database,
      menuPoll: const Duration(milliseconds: 5),
      menuPatience: const Duration(milliseconds: 600),
    );
    context = ServerToolContext(
      database: database,
      data: DataService(database, clock: () => t0),
      dataDirectory: '/nowhere',
      clock: () => t0,
    );
    tools = SessionToolSet(context, prompts: prompts, registry: registry);
    registry.open(
      'karmashala_s1',
      PtySpawnRequest(
        argv: const ['claude'],
        workingDirectory: '/src/shop/api',
        environment: const {},
        columns: 120,
        rows: 30,
      ),
    );
    pane = _ChecklistPane(launcher.handles.last);
    await pumpEventQueue();
    status.tick();
  });

  tearDown(() async {
    pane.close();
    context.close();
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  Future<Map<String, Object?>> answer(Map<String, Object?> arguments) async =>
      (await tools.call('session_answer', {
            'sessionId': 's1',
            ...arguments,
          }, 'caller')!)
          as Map<String, Object?>;

  test('the transcript names its boxes, ticks and submit row', () async {
    final read =
        (await tools.call('session_transcript', {'sessionId': 's1'}, null)!)
            as Map<String, Object?>;
    expect(read['menu'], {
      'prompt': anyElement(contains('2 new MCP servers found')),
      'options': ['dart', 'marionette', 'Enable selected'],
      'highlighted': 0,
      'checked': [true, true, null],
      'boxes': [0, 1],
      'submit': 2,
    });
  });

  test('ticks set each box, then submit', () async {
    final answered = await answer({
      'ticks': [true, false],
    });

    expect(pane.keys, ['\x1b[B', ' ', '\x1b[B', '\r']);
    expect(pane.closedWith, [true, false]);
    expect(answered['answered'], 'Enabled dart');
    expect(
      database.query('SELECT * FROM session_decisions;'),
      hasLength(1),
      reason: 'filed as a decision',
    );
  });

  test('approve ticks every box and submits', () async {
    final answered = await answer({'decision': 'approve'});

    expect(pane.keys, ['\x1b[B', '\x1b[B', '\r']);
    expect(pane.closedWith, [true, true]);
    expect(answered['answered'], 'Enabled dart, marionette');
  });

  test('deny rejects them all with Esc', () async {
    final denied = await answer({'decision': 'deny'});
    expect(pane.keys, ['\x1b']);
    expect(pane.closedWith, 'rejected');
    expect(denied['answered'], 'Rejected all');
  });

  test('dismiss rejects them all with Esc', () async {
    final dismissed = await answer({'dismiss': true});
    expect(pane.keys, ['\x1b']);
    expect(dismissed['answered'], 'Rejected all');
  });

  test(
    'ticks that miss a box, or come with a decision, press nothing',
    () async {
      await expectLater(
        answer({
          'ticks': [true],
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('"dart", "marionette"'),
          ),
        ),
      );
      await expectLater(
        answer({
          'ticks': [true, true],
          'decision': 'approve',
        }),
        throwsA(isA<ArgumentError>()),
      );
      expect(pane.keys, isEmpty);
    },
  );
}

/// The checklist in a fake pane that redraws it the way Claude Code does on
/// each key: ↓ moves down to "Enable selected", Space toggles a box, Enter on
/// "Enable selected" and Esc close it.
class _ChecklistPane {
  _ChecklistPane(this.agent) {
    _draw();
    _timer = Timer.periodic(const Duration(milliseconds: 1), (_) => _read());
  }

  final FakePtyHandle agent;
  late final Timer _timer;
  var _seen = 0;
  var highlighted = 0;
  final ticks = [true, true];
  final keys = <String>[];
  Object? closedWith;

  void close() => _timer.cancel();

  void _read() {
    while (_seen < agent.writes.length) {
      final key = utf8.decode(agent.writes[_seen++]);
      keys.add(key);
      if (closedWith != null) continue;
      switch (key) {
        case '\x1b[B' when highlighted < 2:
          highlighted++;
        case ' ' when highlighted < 2:
          ticks[highlighted] = !ticks[highlighted];
        case '\r' when highlighted == 2:
          closedWith = List.of(ticks);
        case '\x1b':
          closedWith = 'rejected';
      }
      _draw();
    }
  }

  void _draw() {
    final rows = closedWith != null
        ? const ['❯ ', '  ⏸ manual mode on · ? for shortcuts']
        : [
            ...kOwnersMcpChecklist.take(6),
            for (final (i, name) in ['dart', 'marionette'].indexed)
              '  ${i == highlighted ? '❯' : ' '} '
                  '${ticks[i] ? '[✔]' : '[ ]'} $name',
            '  ${highlighted == 2 ? '❯' : ' '}    Enable selected',
            ...kOwnersMcpChecklist.skip(9),
          ];
    agent.emit(utf8.encode('\x1b[2J\x1b[H${rows.join('\r\n')}'));
  }
}
