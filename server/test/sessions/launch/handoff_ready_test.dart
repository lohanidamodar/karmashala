import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/src/sessions/launch/handoff_delivery.dart';
import 'package:karmashala_host/src/sessions/launch/session_handoffs.dart';
import 'package:karmashala_host/src/status/daemon_agent_status.dart';
import 'package:karmashala_host/src/status/turn_settlement.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// When the server's handoff delivery takes a composer for ready: a dialog
/// drawn before the status has read it — the keeper not yet tracking the row
/// — holds the opening back however quiet it sits (review 2026-11-12, 1b),
/// while a quiet screen with nothing drawn on it still takes it.
void main() {
  final t0 = DateTime.utc(2026, 11, 12, 12);

  late AppDatabase database;
  late Directory temp;
  late SessionRegistry registry;
  late FakePtyLauncher launcher;
  late DaemonAgentStatus status;
  late TurnSettlement turns;
  late HandoffDelivery delivery;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('handoff_ready');
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
    turns = TurnSettlement(status: status, quietPeriod: Duration.zero);
    delivery = HandoffDelivery.forServer(
      handoffs: SessionHandoffs(
        dao: SessionHandoffDao(database),
        root: Directory(p.join(temp.path, 'root')),
        now: () => t0,
      ),
      status: status,
      turns: turns,
      deliver: (_, _, _) async =>
          const SessionSent(sent: true, via: SessionSent.readBack),
    );
  });

  tearDown(() async {
    await delivery.close();
    await turns.close();
    await status.close();
    for (final handle in launcher.handles) {
      handle.finish(0);
    }
    await registry.shutdown();
    database.close();
    temp.deleteSync(recursive: true);
  });

  Future<FakePtyHandle> open(String output) async {
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
    final agent = launcher.handles.last..emit(utf8.encode(output));
    await pumpEventQueue();
    return agent;
  }

  String trustPrompt() {
    final text = File(
      '../app/test/features/agents/fixtures/claude-code-trust-prompt.raw',
    ).readAsStringSync();
    final teardown = text.indexOf('Session terminated');
    return teardown < 0 ? text : text.substring(0, teardown);
  }

  test('a dialog the status has not read yet is never ready', () async {
    await open(trustPrompt());
    expect(status.statusOf('s1'), isNull, reason: 'no tick has run');
    expect(turns.quiet('s1') || turns.quiet('s1'), isTrue);

    expect(delivery.ready('s1'), isFalse);
  });

  test('a quiet screen with nothing drawn on it is still ready', () async {
    await open('\x1b[2J\x1b[Hstarting up\r\n');
    turns.quiet('s1');

    expect(delivery.ready('s1'), isTrue);
  });
}
