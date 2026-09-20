import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import '../domain/comparison.dart';

/// Data-access for persisted fan-out comparisons. Reads always return a
/// comparison with its candidates attached; the alternative was two round trips.
class ComparisonDao {
  ComparisonDao(this._db);

  final AppDatabase _db;

  /// Writes a comparison and every candidate in one transaction, so a fan-out is
  /// never half-recorded.
  void insert(Comparison comparison) {
    _db.transaction(() {
      _db.execute(
        'INSERT INTO fanout_comparisons '
        '(id, repository_id, prompt, created_at, finished_at, outcome, '
        'winner_candidate_id, merged_commit, archived) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          comparison.id,
          comparison.repositoryId,
          comparison.prompt,
          isoFromDate(comparison.createdAt),
          comparison.finishedAt == null
              ? null
              : isoFromDate(comparison.finishedAt!),
          comparison.outcome.name,
          comparison.winnerCandidateId,
          comparison.mergedCommit,
          intFromBool(comparison.archived),
        ],
      );
      for (final candidate in comparison.candidates) {
        _insertCandidate(candidate);
      }
    });
  }

  void _insertCandidate(ComparisonCandidate candidate) {
    _db.execute(
      'INSERT INTO fanout_candidates '
      '(id, comparison_id, position, session_id, installation_id, agent_id, '
      'worktree_environment_id, worktree_path, branch, launch, failure, '
      'files_changed, insertions, deletions, commits, diff_captured_at, '
      'worktree_removed, verdict, verdict_label, verdict_run_id, '
      'verdict_producer_session_id, notes) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
      '?);',
      [
        candidate.id,
        candidate.comparisonId,
        candidate.position,
        candidate.sessionId,
        candidate.installationId,
        candidate.agentId,
        candidate.worktree?.environmentId,
        candidate.worktree?.path,
        candidate.branch,
        candidate.launch.name,
        candidate.failure,
        candidate.diff?.filesChanged,
        candidate.diff?.insertions,
        candidate.diff?.deletions,
        candidate.diff?.commits,
        candidate.diff == null ? null : isoFromDate(candidate.diff!.capturedAt),
        intFromBool(candidate.worktreeRemoved),
        candidate.evidence?.verdict.name,
        candidate.evidence?.label,
        candidate.evidence?.runId,
        candidate.evidence?.producerSessionId,
        candidate.notes,
      ],
    );
  }

  /// Records the diff a candidate showed the last time it was read.
  void updateDiff(String candidateId, CandidateDiffStat stat) {
    _db.execute(
      'UPDATE fanout_candidates SET files_changed = ?, insertions = ?, '
      'deletions = ?, commits = ?, diff_captured_at = ? WHERE id = ?;',
      [
        stat.filesChanged,
        stat.insertions,
        stat.deletions,
        stat.commits,
        isoFromDate(stat.capturedAt),
        candidateId,
      ],
    );
  }

  /// Marks a candidate's worktree gone. The row itself is never deleted.
  void markWorktreeRemoved(String candidateId) {
    _db.execute(
      'UPDATE fanout_candidates SET worktree_removed = 1 WHERE id = ?;',
      [candidateId],
    );
  }

  /// Attaches (or clears) a verification verdict.
  void updateEvidence(String candidateId, CandidateEvidence? evidence) {
    _db.execute(
      'UPDATE fanout_candidates SET verdict = ?, verdict_label = ?, '
      'verdict_run_id = ?, verdict_producer_session_id = ? WHERE id = ?;',
      [
        evidence?.verdict.name,
        evidence?.label,
        evidence?.runId,
        evidence?.producerSessionId,
        candidateId,
      ],
    );
  }

  void updateNotes(String candidateId, String? notes) {
    _db.execute('UPDATE fanout_candidates SET notes = ? WHERE id = ?;', [
      notes,
      candidateId,
    ]);
  }

  /// Records the winner and how the comparison ended.
  void updateOutcome(
    String comparisonId, {
    required ComparisonOutcome outcome,
    String? winnerCandidateId,
    String? mergedCommit,
    DateTime? finishedAt,
  }) {
    _db.execute(
      'UPDATE fanout_comparisons SET outcome = ?, winner_candidate_id = ?, '
      'merged_commit = ?, finished_at = ? WHERE id = ?;',
      [
        outcome.name,
        winnerCandidateId,
        mergedCommit,
        finishedAt == null ? null : isoFromDate(finishedAt),
        comparisonId,
      ],
    );
  }

  /// Marks the winner without claiming anything was merged.
  void updateWinner(String comparisonId, String? winnerCandidateId) {
    _db.execute(
      'UPDATE fanout_comparisons SET winner_candidate_id = ? WHERE id = ?;',
      [winnerCandidateId, comparisonId],
    );
  }

  void setArchived(String comparisonId, bool archived) {
    _db.execute('UPDATE fanout_comparisons SET archived = ? WHERE id = ?;', [
      intFromBool(archived),
      comparisonId,
    ]);
  }

  Comparison? getById(String id) {
    final rows = _db.query('SELECT * FROM fanout_comparisons WHERE id = ?;', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first, candidatesOf(id));
  }

  /// Every comparison, newest first. [repositoryId] narrows it to one
  /// repository; [includeArchived] brings back the ones put away.
  List<Comparison> getAll({
    String? repositoryId,
    bool includeArchived = false,
  }) {
    final where = <String>[
      if (repositoryId != null) 'repository_id = ?',
      if (!includeArchived) 'archived = 0',
    ];
    final rows = _db.query(
      'SELECT * FROM fanout_comparisons'
      '${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'} '
      'ORDER BY created_at DESC, id DESC;',
      [?repositoryId],
    );
    return [
      for (final row in rows) _fromRow(row, candidatesOf(row['id']! as String)),
    ];
  }

  List<ComparisonCandidate> candidatesOf(String comparisonId) {
    final rows = _db.query(
      'SELECT * FROM fanout_candidates WHERE comparison_id = ? '
      'ORDER BY position;',
      [comparisonId],
    );
    return rows.map(_candidateFromRow).toList();
  }

  /// The candidate a session belongs to, if it came from a fan-out. Cheap
  /// enough to ask on a session row.
  ComparisonCandidate? candidateForSession(String sessionId) {
    final rows = _db.query(
      'SELECT * FROM fanout_candidates WHERE session_id = ? LIMIT 1;',
      [sessionId],
    );
    return rows.isEmpty ? null : _candidateFromRow(rows.first);
  }

  void delete(String comparisonId) {
    _db.execute('DELETE FROM fanout_comparisons WHERE id = ?;', [comparisonId]);
  }

  Comparison _fromRow(
    Map<String, Object?> row,
    List<ComparisonCandidate> candidates,
  ) => Comparison(
    id: row['id']! as String,
    repositoryId: row['repository_id']! as String,
    prompt: row['prompt']! as String,
    createdAt: dateFromIso(row['created_at']),
    finishedAt: row['finished_at'] == null
        ? null
        : dateFromIso(row['finished_at']),
    outcome: ComparisonOutcome.values.firstWhere(
      (o) => o.name == row['outcome'],
      orElse: () => ComparisonOutcome.pending,
    ),
    winnerCandidateId: row['winner_candidate_id'] as String?,
    mergedCommit: row['merged_commit'] as String?,
    archived: boolFromInt(row['archived']),
    candidates: candidates,
  );

  ComparisonCandidate _candidateFromRow(Map<String, Object?> row) {
    final environmentId = row['worktree_environment_id'] as String?;
    final path = row['worktree_path'] as String?;
    final capturedAt = row['diff_captured_at'] as String?;
    final verdict = row['verdict'] as String?;
    return ComparisonCandidate(
      id: row['id']! as String,
      comparisonId: row['comparison_id']! as String,
      position: row['position']! as int,
      sessionId: row['session_id'] as String?,
      installationId: row['installation_id']! as String,
      agentId: row['agent_id']! as String,
      worktree: environmentId == null || path == null
          ? null
          : EnvironmentPath(environmentId: environmentId, path: path),
      branch: row['branch'] as String?,
      launch: CandidateLaunchState.values.firstWhere(
        (s) => s.name == row['launch'],
        orElse: () => CandidateLaunchState.failed,
      ),
      failure: row['failure'] as String?,
      diff: capturedAt == null
          ? null
          : CandidateDiffStat(
              filesChanged: (row['files_changed'] as int?) ?? 0,
              insertions: (row['insertions'] as int?) ?? 0,
              deletions: (row['deletions'] as int?) ?? 0,
              commits: row['commits'] as int?,
              capturedAt: dateFromIso(capturedAt),
            ),
      worktreeRemoved: boolFromInt(row['worktree_removed']),
      evidence: verdict == null
          ? null
          : CandidateEvidence(
              verdict: EvidenceVerdict.values.firstWhere(
                (v) => v.name == verdict,
                orElse: () => EvidenceVerdict.inconclusive,
              ),
              label: row['verdict_label'] as String?,
              runId: row['verdict_run_id'] as String?,
              producerSessionId: row['verdict_producer_session_id'] as String?,
            ),
      notes: row['notes'] as String?,
    );
  }
}
