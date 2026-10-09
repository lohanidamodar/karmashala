import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/sessions/session_queue.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

class _Clock implements Clock {
  DateTime now = DateTime.utc(2026, 10, 9, 6);
  @override
  DateTime nowUtc() => now;
}

/// A terminal Antigravity session stopped with Esc mid-turn (bug 9): agy's
/// screen says "⎿ Interrupted" over an empty prompt and its idle footer.
/// That is idle, so what waits in its queue goes — session 038649f1 kept
/// two messages queued for 35 minutes behind a turn that had ended.
void main() {
  final t0 = DateTime.utc(2026, 10, 9, 6);
  late AppDatabase database;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late SessionQueue queue;
  late _Clock clock;
  late List<String> delivered;

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO repositories (id, project_id, name, environment_id, path, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['r1', 'p1', 'probe', 'wsl:arch', '/tmp/r70-probe-agy', '$t0'],
    );
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.antigravity, 'wsl:arch', '/usr/bin/agy', '$t0', 1],
    );
    SessionDao(database).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Review',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: t0,
      ),
    );
    clock = _Clock();
    launcher = FakePtyLauncher();
    registry = SessionRegistry(launcher: launcher);
    status = DaemonAgentStatus(
      registry: registry,
      database: database,
      publish: (_, _) {},
      clock: clock,
      interval: const Duration(hours: 1),
    );
    delivered = [];
    var n = 0;
    queue = SessionQueue(
      dao: SessionQueueDao(database),
      status: status,
      turnStartGrace: const Duration(seconds: 30),
      quietPeriod: const Duration(seconds: 30),
      quietPoll: const Duration(milliseconds: 10),
      newId: () => 'q${++n}',
      now: () => clock.now,
    )..deliver = ((_, text) async => delivered.add(text));
    queue.start();
  });

  tearDown(() async {
    await queue.close();
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
  });

  void hook(String event) => status.hook(
    AgentHookEvent(
      agent: AgentIds.antigravity,
      event: event,
      sessionHeader: 's1',
      receivedAt: clock.now,
      body: {
        'conversationId': 'conv-1',
        'workspacePaths': ['/tmp/r70-probe-agy'],
      },
    ),
  );

  for (final fixture in [
    'antigravity-interrupted',
    'antigravity-interrupted-accept-edits',
  ]) {
    test('$fixture.raw: the interrupted screen is idle, and the queued '
        'message goes', () async {
      registry.open(
        'karmashala_s1',
        const PtySpawnRequest(argv: ['agy'], columns: 120, rows: 30),
      );
      hook('PreInvocation');
      expect(
        queue.admit('s1', 'carry on', origin: QueuedMessageOrigin.app),
        isA<AdmitQueued>(),
      );

      // The Esc: the screen settles idle, and no Stop hook says so.
      launcher.handles.last.emit(
        utf8.encode(
          File(
            '../app/test/features/agents/fixtures/$fixture.raw',
          ).readAsStringSync(),
        ),
      );
      await pumpEventQueue();
      clock.now = clock.now.add(const Duration(seconds: 30));
      status.tick();
      await pumpEventQueue();
      expect(delivered, isEmpty, reason: 'a fresh "working" hook stands');

      clock.now = clock.now.add(const Duration(minutes: 6));
      status.tick();
      await pumpEventQueue();
      expect(status.statusOf('s1')!.report.status, AgentActivityStatus.idle);
      expect(delivered, ['carry on']);
    });
  }
}
