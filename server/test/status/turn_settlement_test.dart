import 'dart:async';
import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/sessions/interrupted_turns.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/turn_settlement.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// A turn settles on idle or failed, or â€” for a session seen working whose
/// reader lost it â€” on a screen that stopped moving: asked on demand with no
/// message waiting, and told to the open-turn record.
void main() {
  final t0 = DateTime.utc(2026, 10, 3, 12);
  const quiet = Duration(milliseconds: 300);

  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late TurnSettlement turns;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.codex, 'local', '/bin/codex', '$t0', 1],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Essay',
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
    turns = TurnSettlement(
      status: status,
      quietPeriod: quiet,
      poll: const Duration(milliseconds: 10),
    )..start();
  });

  tearDown(() async {
    await turns.close();
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  Future<void> runAgent() async {
    registry.open(
      'karmashala_s1',
      PtySpawnRequest(
        argv: const ['codex'],
        workingDirectory: '/src',
        environment: const {},
        columns: 120,
        rows: 30,
      ),
    );
    launcher.handles.last.emit(utf8.encode('â€º Ask Codex to do anything\r\n'));
    await pumpEventQueue();
  }

  void says(AgentActivityStatus kind) => status.report(
    's1',
    AgentStatusReport(
      agentId: AgentIds.codex,
      sessionId: 's1',
      status: kind,
      observedAt: DateTime.now().toUtc(),
      source: AgentStatusSource.terminalGrid,
    ),
  );

  Future<void> streams(int count) async {
    for (var i = 0; i < count; i++) {
      launcher.handles.last.emit(utf8.encode('word $i of the essay\r\n'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  test('working, then unknown over a quiet screen: settled, and not busy '
      'with no message waiting', () async {
    await runAgent();
    final settled = <String>[];
    turns.settled.listen(settled.add);
    final queue = SessionQueue(
      dao: SessionQueueDao(database),
      status: status,
      turns: turns,
    )..start();
    addTearDown(queue.close);

    says(AgentActivityStatus.working);
    expect(turns.running('s1'), isTrue);
    says(AgentActivityStatus.unknown);
    expect(queue.busy('s1'), isTrue, reason: 'the screen just moved');

    await Future<void>.delayed(quiet * 2);
    expect(settled, ['s1'], reason: 'told without being asked');
    expect(turns.running('s1'), isFalse);
    expect(queue.busy('s1'), isFalse);
  });

  test('asked on demand, a screen quiet since the turn was lost is '
      'settled', () async {
    await runAgent();
    says(AgentActivityStatus.working);
    says(AgentActivityStatus.unknown);
    await turns.close();
    // No poll runs now: the answer comes from the screen when asked.
    turns = TurnSettlement(status: status, quietPeriod: quiet)..start();
    says(AgentActivityStatus.working);
    says(AgentActivityStatus.unknown);
    expect(turns.running('s1'), isTrue);
    await Future<void>.delayed(quiet * 2);
    expect(turns.running('s1'), isFalse);
  });

  test('a screen still streaming keeps the turn running and open', () async {
    await runAgent();
    final record = OpenTurns(read: () => null, write: (_) {});
    final lifecycle = StreamController<LifecycleEvent>.broadcast();
    final follow = followOpenTurns(
      record,
      statuses: status.changes,
      lifecycle: lifecycle.stream,
      runsHere: (_) => true,
      clock: () => t0,
      settled: turns.settled,
    );
    addTearDown(() async {
      for (final subscription in follow) {
        await subscription.cancel();
      }
      await lifecycle.close();
    });

    says(AgentActivityStatus.working);
    says(AgentActivityStatus.unknown);
    await streams(15);
    expect(turns.running('s1'), isTrue);
    expect(record.open.keys, ['s1']);

    await Future<void>.delayed(quiet * 2);
    expect(turns.running('s1'), isFalse);
    expect(record.open, isEmpty, reason: 'closed on the quiet settle');
  });

  test('idle settles at once', () async {
    await runAgent();
    says(AgentActivityStatus.working);
    says(AgentActivityStatus.unknown);
    says(AgentActivityStatus.idle);
    expect(turns.running('s1'), isFalse);
  });
}
