import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/mcp/launcher_control_server.dart';
import 'package:chitragupta_local_ipc/chitragupta_local_ipc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'comparison_fixtures.dart';

/// `fanout_list` and `fanout_get`, driven over the real owner-only socket
/// rather than by calling a private method — an agent reporting on a comparison
/// goes through exactly this path.
void main() {
  late Directory tmp;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('chitra_fanout_mcp_');
    final db = seedDatabase();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Object?> call(
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    final handshake =
        jsonDecode(File(p.join(tmp.path, 'mcp_bridge.json')).readAsStringSync())
            as Map<String, Object?>;
    final raw = await LocalRpcClient.call(
      handshake['socketPath']! as String,
      jsonEncode({
        'tool': tool,
        'arguments': args,
        'token': handshake['token'],
      }),
    );
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    if (decoded['ok'] != true) throw StateError('${decoded['error']}');
    return decoded['result'];
  }

  test('both tools are advertised to the bridge', () {
    final names = [
      for (final s in LauncherControlServer.toolSchemas) s['name'],
    ];
    expect(names, containsAll(<String>['fanout_list', 'fanout_get']));
    for (final schema in LauncherControlServer.toolSchemas) {
      if (schema['name'] != 'fanout_get') continue;
      final input = schema['inputSchema']! as Map<String, dynamic>;
      expect(input['required'], ['id']);
    }
  });

  test('fanout_list is a compact row per comparison', () async {
    final rows = (await call('fanout_list'))! as List<Object?>;
    expect(rows, hasLength(1));
    final row = rows.single! as Map<String, Object?>;
    expect(row['id'], 'cmp-1');
    expect(row['prompt'], 'Make the parser faster');
    expect(row['repository'], 'app');
    expect(row['outcome'], 'merged');
    expect(row['winner'], 'claudeCode');
    expect(row['archived'], isFalse);

    final candidates = row['candidates']! as List<Object?>;
    expect(candidates, hasLength(3));
    expect(
      [for (final c in candidates) (c! as Map)['agentId']],
      ['claudeCode', 'codex', 'flakyCli'],
    );
    expect((candidates.first! as Map)['diff'], '4 files +120 −18 · 2 commits');
    expect((candidates.last! as Map)['state'], 'failed');
    // Compact: no diff text, no worktree paths in the list.
    expect(row.containsKey('mergedCommit'), isFalse);
  });

  test('fanout_get is the full record, worktree removal included', () async {
    final record =
        (await call('fanout_get', {'id': 'cmp-1'}))! as Map<String, Object?>;
    expect(record['prompt'], startsWith('Make the parser faster'));
    expect(record['mergedCommit'], 'abc1234def5678');
    expect(record['winnerAgentId'], 'claudeCode');

    final candidates = record['candidates']! as List<Object?>;
    final winner = candidates.first! as Map<String, Object?>;
    expect(winner['isWinner'], isTrue);
    expect(winner['branch'], 'session/abcd1234');
    expect(winner['worktreeRemoved'], isFalse);
    expect((winner['diff']! as Map)['insertions'], 120);
    expect((winner['verdict']! as Map)['verdict'], 'passed');

    final loser = candidates[1]! as Map<String, Object?>;
    expect(loser['worktreeRemoved'], isTrue);
    expect(
      (loser['diff']! as Map)['summary'],
      '9 files +400 −260',
      reason: 'the record of a worktree that no longer exists',
    );

    final never = candidates.last! as Map<String, Object?>;
    expect(never['state'], 'failed');
    expect(never['failure'], 'Bad state: could not start flakyCli');
  });

  test('an unknown comparison is an error, not an empty record', () async {
    await expectLater(
      call('fanout_get', {'id': 'nope'}),
      throwsA(isA<StateError>()),
    );
  });
}
