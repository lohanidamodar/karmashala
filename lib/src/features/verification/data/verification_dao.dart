import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/verification_artifact.dart';
import '../domain/verification_run.dart';
import '../domain/verification_step.dart';
import '../domain/verification_target.dart';

/// Data-access for verification runs, their steps and their artifact rows.
/// Hand-written SQL, no codegen.
class VerificationDao {
  VerificationDao(this._db);

  final AppDatabase _db;

  // --- Runs ------------------------------------------------------------------

  void insertRun(VerificationRun run) {
    _db.execute(
      'INSERT INTO verification_runs '
      '(id, title, target_kind, target_url, target_serial, target_package, '
      'session_id, produced_by_session_id, started_at, finished_at, verdict, '
      'reason, artifact_directory) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        run.id,
        run.title,
        run.target.kind.name,
        run.target.url,
        run.target.serial,
        run.target.packageName,
        run.sessionId,
        run.producedBySessionId,
        isoFromDate(run.startedAt),
        run.finishedAt == null ? null : isoFromDate(run.finishedAt!),
        run.verdict?.name,
        run.reason,
        run.artifactDirectory,
      ],
    );
  }

  /// Closes a run with its verdict. The only update a finished run ever gets —
  /// steps and artifacts are append-only, so evidence cannot be edited after
  /// the fact.
  /// [producedBySessionId] names the session signing off. `COALESCE` rather
  /// than a plain assignment: a caller that cannot name itself must not erase
  /// the producer recorded when the run was started.
  void finishRun(
    String id, {
    required DateTime finishedAt,
    required VerificationVerdict verdict,
    String? reason,
    String? producedBySessionId,
  }) {
    _db.execute(
      'UPDATE verification_runs SET finished_at = ?, verdict = ?, reason = ?, '
      'produced_by_session_id = COALESCE(?, produced_by_session_id) '
      'WHERE id = ?;',
      [
        isoFromDate(finishedAt),
        verdict.name,
        reason,
        producedBySessionId,
        id,
      ],
    );
  }

  /// Attaches (or detaches) a session after the fact.
  void updateSessionId(String id, String? sessionId) {
    _db.execute('UPDATE verification_runs SET session_id = ? WHERE id = ?;', [
      sessionId,
      id,
    ]);
  }

  /// Runs newest first, without their steps or artifacts — the list view.
  List<VerificationRun> listRuns({int limit = 50, String? sessionId}) {
    final rows = sessionId == null
        ? _db.query(
            'SELECT * FROM verification_runs '
            'ORDER BY started_at DESC, id DESC LIMIT ?;',
            [limit],
          )
        : _db.query(
            'SELECT * FROM verification_runs WHERE session_id = ? '
            'ORDER BY started_at DESC, id DESC LIMIT ?;',
            [sessionId, limit],
          );
    return rows.map(_runFromRow).toList();
  }

  /// One run with everything it recorded.
  VerificationRun? getRun(String id) {
    final rows = _db.query('SELECT * FROM verification_runs WHERE id = ?;', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return _runFromRow(
      rows.first,
    ).copyWith(steps: stepsFor(id), artifacts: artifactsFor(id));
  }

  /// The most recent run that is still open, if any. Used to re-adopt a run
  /// after a restart rather than silently starting a second one.
  VerificationRun? openRun() {
    final rows = _db.query(
      'SELECT * FROM verification_runs WHERE finished_at IS NULL '
      'ORDER BY started_at DESC, id DESC LIMIT 1;',
    );
    return rows.isEmpty ? null : _runFromRow(rows.first);
  }

  /// Runs whose id starts with [prefix], newest first.
  ///
  /// A full UUID is a lot to ask a caller to retype, so `verification_get`
  /// accepts a short prefix the way git accepts a short hash — and this is what
  /// lets it say "that prefix matches three runs" instead of guessing.
  List<VerificationRun> findByPrefix(String prefix) {
    if (prefix.trim().isEmpty) return const [];
    final rows = _db.query(
      "SELECT * FROM verification_runs WHERE id LIKE ? ESCAPE '\\' "
      'ORDER BY started_at DESC, id DESC LIMIT 20;',
      ['${prefix.replaceAll('%', r'\%').replaceAll('_', r'\_')}%'],
    );
    return rows.map(_runFromRow).toList();
  }

  void deleteRun(String id) {
    _db.execute('DELETE FROM verification_runs WHERE id = ?;', [id]);
  }

  // --- Steps -----------------------------------------------------------------

  void insertStep(String runId, VerificationStep step) {
    _db.execute(
      'INSERT INTO verification_steps '
      '(run_id, ordinal, kind, summary, detail, ok, at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?);',
      [
        runId,
        step.ordinal,
        step.kind.name,
        step.summary,
        step.detail,
        intFromBool(step.ok),
        isoFromDate(step.at),
      ],
    );
  }

  List<VerificationStep> stepsFor(String runId) {
    final rows = _db.query(
      'SELECT * FROM verification_steps WHERE run_id = ? ORDER BY ordinal;',
      [runId],
    );
    return [
      for (final row in rows)
        VerificationStep(
          ordinal: row['ordinal']! as int,
          kind: VerificationStepKind.parse(row['kind'] as String?),
          summary: row['summary']! as String,
          detail: row['detail'] as String?,
          ok: boolFromInt(row['ok']),
          at: dateFromIso(row['at']),
        ),
    ];
  }

  /// The highest ordinal used so far, or 0. Lets a recorder resume numbering.
  int lastOrdinal(String runId) {
    final rows = _db.query(
      'SELECT MAX(ordinal) AS n FROM verification_steps WHERE run_id = ?;',
      [runId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  // --- Artifacts -------------------------------------------------------------

  void insertArtifact(VerificationArtifact artifact) {
    _db.execute(
      'INSERT INTO verification_artifacts '
      '(id, run_id, step_ordinal, kind, label, relative_path, byte_size, at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
      [
        artifact.id,
        artifact.runId,
        artifact.stepOrdinal,
        artifact.kind.name,
        artifact.label,
        artifact.relativePath,
        artifact.byteSize,
        isoFromDate(artifact.at),
      ],
    );
  }

  List<VerificationArtifact> artifactsFor(String runId) {
    final rows = _db.query(
      'SELECT * FROM verification_artifacts WHERE run_id = ? ORDER BY at, id;',
      [runId],
    );
    return [
      for (final row in rows)
        VerificationArtifact(
          id: row['id']! as String,
          runId: row['run_id']! as String,
          stepOrdinal: row['step_ordinal'] as int?,
          kind: VerificationArtifactKind.parse(row['kind'] as String?),
          label: row['label']! as String,
          relativePath: row['relative_path']! as String,
          byteSize: row['byte_size']! as int,
          at: dateFromIso(row['at']),
        ),
    ];
  }

  VerificationRun _runFromRow(Map<String, Object?> row) {
    final kind = VerificationTargetKind.parse(row['target_kind'] as String?);
    return VerificationRun(
      id: row['id']! as String,
      title: row['title']! as String,
      target: kind == VerificationTargetKind.device
          ? VerificationTarget.device(
              serial: (row['target_serial'] as String?) ?? '',
              packageName: row['target_package'] as String?,
            )
          : VerificationTarget.browser((row['target_url'] as String?) ?? ''),
      sessionId: row['session_id'] as String?,
      producedBySessionId: row['produced_by_session_id'] as String?,
      startedAt: dateFromIso(row['started_at']),
      finishedAt: row['finished_at'] == null
          ? null
          : dateFromIso(row['finished_at']),
      verdict: VerificationVerdict.parse(row['verdict'] as String?),
      reason: row['reason'] as String?,
      artifactDirectory: row['artifact_directory']! as String,
    );
  }
}
