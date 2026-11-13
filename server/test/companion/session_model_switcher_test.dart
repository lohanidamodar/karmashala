import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/companion/session_model_switcher.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// **A model change reaches the running session the moment that is safe, and
/// never before.** The server's own typist, for a session no pane of the
/// asking client shows: idle is typed now, mid-turn waits for the turn to end,
/// and anything nothing can vouch for is left to the next launch.
void main() {
  late Map<String, Session> rows;
  late Map<String, AgentActivityStatus?> status;
  late Set<String> running;
  late List<(String, String)> typed;
  late List<(String, String)> notices;
  late StreamController<String> idle;
  late SessionModelSwitcher switcher;
  Object? typeRefusal;

  Session row(
    String id, {
    String agentInstallationId = 'claude',
    String? modelId,
  }) => Session(
    id: id,
    modelId: modelId,
    repositoryId: 'r1',
    agentInstallationId: agentInstallationId,
    title: 'Fix the cart',
    useWorktree: false,
    status: SessionStatus.running,
    createdAt: DateTime.utc(2026, 11, 13),
  );

  setUp(() {
    rows = {'s1': row('s1'), 'cx': row('cx', agentInstallationId: 'codex')};
    status = {'s1': AgentActivityStatus.idle, 'cx': AgentActivityStatus.idle};
    running = {'s1', 'cx'};
    typed = [];
    notices = [];
    typeRefusal = null;
    idle = StreamController<String>.broadcast(sync: true);
    switcher = SessionModelSwitcher(
      rowOf: (id) => rows[id],
      record: (id, model) => rows[id] = row(
        id,
        agentInstallationId: rows[id]!.agentInstallationId,
        modelId: model,
      ),
      agentOf: (row) => AgentRegistry.builtIn.byId(
        row.agentInstallationId == 'codex'
            ? AgentIds.codex
            : AgentIds.claudeCode,
      ),
      defaultModelOf: (_) => null,
      runningHere: running.contains,
      statusOf: (id) => status[id],
      type: (id, line) async {
        if (typeRefusal case final refusal?) throw refusal;
        typed.add((id, line));
      },
      becameIdle: idle.stream,
      notice: (id, message) => notices.add((id, message)),
    );
  });

  tearDown(() async {
    switcher.dispose();
    await idle.close();
  });

  test(
    'idle: the model command is typed now, and the row is written',
    () async {
      final answer = await switcher.setModel('s1', 'opus');

      expect(answer.outcome, SessionModelOutcome.now);
      expect(answer.line, '/model opus');
      expect(typed, [('s1', '/model opus')]);
      expect(rows['s1']!.modelId, 'opus');
    },
  );

  test('mid-turn: nothing is typed until the turn ends, then the model '
      'recorded then is', () async {
    status['s1'] = AgentActivityStatus.working;

    final answer = await switcher.setModel('s1', 'opus');
    expect(answer.outcome, SessionModelOutcome.afterTurn);
    expect(typed, isEmpty, reason: 'a line typed mid-turn lands in the turn');
    expect(switcher.holds('s1'), isTrue);
    expect(rows['s1']!.modelId, 'opus');

    // A second pick while it waits replaces the first.
    await switcher.setModel('s1', 'haiku');
    status['s1'] = AgentActivityStatus.idle;
    idle.add('s1');
    await pumpEventQueue();

    expect(typed, [('s1', '/model haiku')]);
    expect(switcher.holds('s1'), isFalse);
    expect(notices.single.$2, contains('/model haiku'));
  });

  test('an open prompt waits too: a typed line would answer it', () async {
    status['s1'] = AgentActivityStatus.awaitingApproval;

    expect(
      (await switcher.setModel('s1', 'opus')).outcome,
      SessionModelOutcome.afterTurn,
    );
    expect(typed, isEmpty);
  });

  test(
    'a status nothing reports is left to the next launch, never held',
    () async {
      status['s1'] = AgentActivityStatus.unknown;

      expect(
        (await switcher.setModel('s1', 'opus')).outcome,
        SessionModelOutcome.recorded,
      );
      expect(typed, isEmpty);
      expect(switcher.holds('s1'), isFalse);
      expect(rows['s1']!.modelId, 'opus');
    },
  );

  test('nothing running here: recorded for the next launch', () async {
    running.clear();

    expect(
      (await switcher.setModel('s1', 'opus')).outcome,
      SessionModelOutcome.recorded,
    );
    expect(typed, isEmpty);
    expect(rows['s1']!.modelId, 'opus');
  });

  test('a type the terminal refuses is recorded, not claimed', () async {
    typeRefusal = StateError('somebody else is driving it');

    expect(
      (await switcher.setModel('s1', 'opus')).outcome,
      SessionModelOutcome.recorded,
    );
  });

  test(
    'handed back to a default that names no model: nothing to type',
    () async {
      rows['s1'] = row('s1', modelId: 'opus');

      expect(
        (await switcher.setModel('s1', null)).outcome,
        SessionModelOutcome.recorded,
      );
      expect(rows['s1']!.modelId, isNull);
      expect(typed, isEmpty);
    },
  );

  test('Codex, idle: its own picker is opened, since /model takes no '
      'name', () async {
    final answer = await switcher.setModel('cx', 'gpt-5.5');

    expect(answer.outcome, SessionModelOutcome.pickerOpened);
    expect(typed, [('cx', '/model')]);
  });

  test('Codex mid-turn: not even the picker is typed, nor held', () async {
    status['cx'] = AgentActivityStatus.working;

    expect(
      (await switcher.setModel('cx', 'gpt-5.5')).outcome,
      SessionModelOutcome.recorded,
    );
    expect(typed, isEmpty);
    expect(switcher.holds('cx'), isFalse);
  });

  test('a session that is gone is refused notFound', () async {
    await expectLater(
      switcher.setModel('gone', 'opus'),
      throwsA(
        isA<DataRefused>().having(
          (r) => r.code,
          'code',
          DataRefusalCode.notFound,
        ),
      ),
    );
  });

  test('a held switch whose session ended before idle types nothing', () async {
    status['s1'] = AgentActivityStatus.working;
    await switcher.setModel('s1', 'opus');
    running.clear();
    status['s1'] = AgentActivityStatus.idle;
    idle.add('s1');
    await pumpEventQueue();

    expect(typed, isEmpty);
    expect(notices, isEmpty);
  });
}
