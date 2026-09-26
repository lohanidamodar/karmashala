import 'package:karmashala/src/features/mcp/mcp_tool_dispatcher.dart';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/fanout/data/comparison_dao.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';
import 'comparison_fixtures.dart';

/// `fanout_list` and `fanout_get`, driven over the real owner-only socket
/// rather than by calling a private method — an agent reporting on a comparison
/// goes through exactly this path.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('karmashala_fanout_mcp_');
    db = seedDatabase();
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
    final names = [for (final s in McpToolDispatcher.toolSchemas) s['name']];
    expect(names, containsAll(<String>['fanout_list', 'fanout_get']));
    for (final schema in McpToolDispatcher.toolSchemas) {
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

  /// A comparison whose three candidates cover the three attribution states:
  /// a verdict its own session produced, one another session produced, and one
  /// with no producer recorded at all.
  void seedAttributedComparison() {
    ComparisonDao(db).insert(
      Comparison(
        id: 'cmp-attr',
        repositoryId: 'r1',
        prompt: 'Who checked this?',
        createdAt: testTime,
        outcome: ComparisonOutcome.pending,
        candidates: const [
          ComparisonCandidate(
            id: 'c-self',
            comparisonId: 'cmp-attr',
            position: 0,
            installationId: 'a1',
            agentId: 'claudeCode',
            launch: CandidateLaunchState.started,
            sessionId: 's-self',
            evidence: CandidateEvidence(
              verdict: EvidenceVerdict.passed,
              label: '12 tests, 0 failed',
              runId: 'run-self',
              producerSessionId: 's-self',
            ),
          ),
          ComparisonCandidate(
            id: 'c-checked',
            comparisonId: 'cmp-attr',
            position: 1,
            installationId: 'a2',
            agentId: 'codex',
            launch: CandidateLaunchState.started,
            sessionId: 's-checked',
            evidence: CandidateEvidence(
              verdict: EvidenceVerdict.passed,
              label: '12 tests, 0 failed',
              runId: 'run-checked',
              producerSessionId: 's-reviewer',
            ),
          ),
          ComparisonCandidate(
            id: 'c-blank',
            comparisonId: 'cmp-attr',
            position: 2,
            installationId: 'a3',
            agentId: 'gemini',
            launch: CandidateLaunchState.started,
            sessionId: 's-blank',
            evidence: CandidateEvidence(
              verdict: EvidenceVerdict.failed,
              label: '12 tests, 1 failed',
            ),
          ),
        ],
      ),
    );
  }

  test('a verdict an agent reads names the session that produced it', () async {
    seedAttributedComparison();
    final record =
        (await call('fanout_get', {'id': 'cmp-attr'}))! as Map<String, Object?>;
    final candidates = record['candidates']! as List<Object?>;

    final self = (candidates[0]! as Map)['verdict']! as Map<String, Object?>;
    expect(self['producedBySessionId'], 's-self');
    expect(self['attribution'], 'author');
    expect(self['attributionLabel'], 'Self-verified');

    final checked = (candidates[1]! as Map)['verdict']! as Map<String, Object?>;
    expect(checked['producedBySessionId'], 's-reviewer');
    expect(checked['attribution'], 'independent');
    expect(checked['attributionLabel'], 'Independently verified');
  });

  test('"nobody recorded a verifier" is stated, not left out', () async {
    seedAttributedComparison();
    final record =
        (await call('fanout_get', {'id': 'cmp-attr'}))! as Map<String, Object?>;
    final blank =
        ((record['candidates']! as List<Object?>)[2]! as Map)['verdict']!
            as Map<String, Object?>;

    // The key is present and null. An omitted producer reads as an oversight
    // in the tool, which is exactly how an unattributed pass gets read as a
    // checked one.
    expect(blank.containsKey('producedBySessionId'), isTrue);
    expect(blank['producedBySessionId'], isNull);
    expect(blank['attribution'], 'notRecorded');
    expect(blank['attributionLabel'], 'Verifier not recorded');
  });

  test('the tool says it carries attribution before it is called', () {
    final schema = McpToolDispatcher.toolSchemas.firstWhere(
      (s) => s['name'] == 'fanout_get',
    );
    expect(schema['description'], contains('who produced'));
  });
}
