import 'package:agent_cli/process.dart';
import 'package:karmashala_comparisons/comparisons.dart';
import 'package:karmashala_comparisons/store.dart';
import 'package:karmashala_host/src/mcp/tools/fanout_tool_set.dart';
import 'package:test/test.dart';

import 'tool_harness.dart';

/// `fanout_list` and `fanout_get`, run by the server (slice 2b) from the
/// store: the record of one prompt run on several agents, including the
/// worktrees that are gone and who produced each verdict.
void main() {
  late ToolHarness h;
  late FanOutToolSet tools;

  const worktree = EnvironmentPath(
    environmentId: 'windows',
    path: r'C:\src\demo\.karmashala-worktrees\abcd1234',
  );

  /// Merged, one candidate's worktree deleted, one agent that never started.
  Comparison seeded() => Comparison(
    id: 'cmp-1',
    repositoryId: 'r1',
    prompt: 'Make the parser faster\nand keep the tests green',
    createdAt: h.now,
    outcome: ComparisonOutcome.merged,
    winnerCandidateId: 'cand-win',
    mergedCommit: 'abc1234def5678',
    finishedAt: h.now,
    candidates: [
      ComparisonCandidate(
        id: 'cand-win',
        comparisonId: 'cmp-1',
        position: 0,
        installationId: 'a1',
        agentId: 'claudeCode',
        launch: CandidateLaunchState.started,
        sessionId: 's-win',
        worktree: worktree,
        branch: 'session/abcd1234',
        diff: CandidateDiffStat(
          filesChanged: 4,
          insertions: 120,
          deletions: 18,
          commits: 2,
          capturedAt: h.now,
        ),
        evidence: const CandidateEvidence(
          verdict: EvidenceVerdict.passed,
          label: '12 tests, 0 failed',
        ),
      ),
      ComparisonCandidate(
        id: 'cand-lost',
        comparisonId: 'cmp-1',
        position: 1,
        installationId: 'a2',
        agentId: 'codex',
        launch: CandidateLaunchState.started,
        sessionId: 's-lost',
        worktree: worktree,
        branch: 'session/efgh5678',
        worktreeRemoved: true,
        diff: CandidateDiffStat(
          filesChanged: 9,
          insertions: 400,
          deletions: 260,
          capturedAt: h.now,
        ),
      ),
      const ComparisonCandidate(
        id: 'cand-dead',
        comparisonId: 'cmp-1',
        position: 2,
        installationId: 'a3',
        agentId: 'flakyCli',
        launch: CandidateLaunchState.failed,
        failure: 'Bad state: could not start flakyCli',
      ),
    ],
  );

  /// Three candidates for the three attribution states: a verdict its own
  /// session produced, one another session produced, and one with no
  /// producer recorded at all.
  Comparison attributed() => Comparison(
    id: 'cmp-attr',
    repositoryId: 'r1',
    prompt: 'Who checked this?',
    createdAt: h.now.subtract(const Duration(hours: 1)),
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
  );

  setUp(() {
    h = ToolHarness();
    // The candidates name sessions and installations this store never held.
    h.db.execute('PRAGMA foreign_keys = OFF;');
    ComparisonDao(h.db).insert(seeded());
    tools = FanOutToolSet(h.context);
  });
  tearDown(() => h.dispose());

  Future<Object?> call(String tool, [Map<String, dynamic> args = const {}]) =>
      h.call(tools, tool, args);

  test('both tools are served, fanout_get needing an id', () {
    expect(
      [for (final s in tools.schemas) s['name']],
      ['fanout_list', 'fanout_get'],
    );
    final input = tools.schemas.last['inputSchema']! as Map<String, Object?>;
    expect(input['required'], ['id']);
    // It says it carries attribution before it is called.
    expect(tools.schemas.last['description'], contains('who produced'));
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

    final candidates = (row['candidates']! as List).cast<Map>();
    expect(
      [for (final c in candidates) c['agentId']],
      ['claudeCode', 'codex', 'flakyCli'],
    );
    expect(candidates.first['diff'], '4 files +120 −18 · 2 commits');
    expect(candidates.last['state'], 'failed');
    // Compact: no diff text, no worktree paths in the list.
    expect(row.containsKey('mergedCommit'), isFalse);
  });

  test('fanout_list narrows, caps and leaves the archived out', () async {
    ComparisonDao(h.db).insert(attributed());
    expect((await call('fanout_list'))! as List, hasLength(2));
    expect(
      [
        for (final row in (await call('fanout_list', {'limit': 1}))! as List)
          (row as Map)['id'],
      ],
      ['cmp-1'],
      reason: 'newest first',
    );
    expect(
      (await call('fanout_list', {'repositoryId': 'r9'}))! as List,
      isEmpty,
    );
    ComparisonDao(h.db).setArchived('cmp-1', true);
    expect((await call('fanout_list'))! as List, hasLength(1));
    expect(
      (await call('fanout_list', {'includeArchived': true}))! as List,
      hasLength(2),
    );
  });

  test('fanout_get is the full record, worktree removal included', () async {
    final record = (await call('fanout_get', {'id': 'cmp-1'}))! as Map;
    expect(record['prompt'], startsWith('Make the parser faster'));
    expect(record['mergedCommit'], 'abc1234def5678');
    expect(record['winnerAgentId'], 'claudeCode');
    expect(record['repositoryId'], 'r1');

    final candidates = (record['candidates']! as List).cast<Map>();
    final winner = candidates.first;
    expect(winner['isWinner'], isTrue);
    expect(winner['branch'], 'session/abcd1234');
    expect(winner['worktree'], worktree.path);
    expect(winner['worktreeRemoved'], isFalse);
    expect((winner['diff']! as Map)['insertions'], 120);
    expect((winner['verdict']! as Map)['verdict'], 'passed');

    final loser = candidates[1];
    expect(loser['worktreeRemoved'], isTrue);
    expect(
      (loser['diff']! as Map)['summary'],
      '9 files +400 −260',
      reason: 'the record of a worktree that no longer exists',
    );

    final never = candidates.last;
    expect(never['state'], 'failed');
    expect(never['failure'], 'Bad state: could not start flakyCli');
  });

  test('an unknown comparison is an error, not an empty record', () async {
    await expectLater(
      call('fanout_get', {'id': 'nope'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'text',
          contains('No comparison with id nope.'),
        ),
      ),
    );
    await expectLater(call('fanout_get'), throwsA(isA<ArgumentError>()));
  });

  test('a verdict an agent reads names the session that produced it', () async {
    ComparisonDao(h.db).insert(attributed());
    final record = (await call('fanout_get', {'id': 'cmp-attr'}))! as Map;
    final candidates = (record['candidates']! as List).cast<Map>();

    final self = candidates[0]['verdict']! as Map;
    expect(self['producedBySessionId'], 's-self');
    expect(self['attribution'], 'author');
    expect(self['attributionLabel'], 'Self-verified');

    final checked = candidates[1]['verdict']! as Map;
    expect(checked['producedBySessionId'], 's-reviewer');
    expect(checked['attribution'], 'independent');
    expect(checked['attributionLabel'], 'Independently verified');

    // "Nobody recorded a verifier" is stated, not left out: the key is present
    // and null.
    final blank = candidates[2]['verdict']! as Map;
    expect(blank.containsKey('producedBySessionId'), isTrue);
    expect(blank['producedBySessionId'], isNull);
    expect(blank['attribution'], 'notRecorded');
    expect(blank['attributionLabel'], 'Verifier not recorded');
  });
}
