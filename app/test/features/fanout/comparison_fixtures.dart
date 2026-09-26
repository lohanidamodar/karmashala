import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/fanout/data/comparison_dao.dart';
import 'package:karmashala/src/features/fanout/domain/comparison.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';

/// A comparison in the state that matters: merged, one candidate's worktree
/// deleted, one agent that never started. Shared by the view and the MCP tests
/// because it is the same record both of them have to render.
const worktree = EnvironmentPath(
  environmentId: 'windows',
  path: r'C:\src\demo\.karmashala-worktrees\abcd1234',
);

Comparison seededComparison({bool merged = true}) => Comparison(
  id: 'cmp-1',
  repositoryId: 'r1',
  prompt: 'Make the parser faster\nand keep the tests green',
  createdAt: testTime,
  outcome: merged ? ComparisonOutcome.merged : ComparisonOutcome.pending,
  winnerCandidateId: merged ? 'cand-win' : null,
  mergedCommit: merged ? 'abc1234def5678' : null,
  finishedAt: merged ? testTime : null,
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
        capturedAt: testTime,
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
        capturedAt: testTime,
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

/// The comparison in a database, its project and repository seeded on
/// [server] (a fresh one when omitted) and mirrored in for the foreign keys;
/// a container that reads the workspace takes `await server.override()`.
AppDatabase seedDatabase({bool merged = true, FakeDataServer? server}) {
  final db = AppDatabase.memory();
  ExecutionEnvironmentDao(db).upsert(windowsEnv());
  (server ?? FakeDataServer()).mirrorInto(db)
    ..projectRows.insert(project())
    ..repositoryRows.insert(repository());
  ComparisonDao(db).insert(seededComparison(merged: merged));
  return db;
}
