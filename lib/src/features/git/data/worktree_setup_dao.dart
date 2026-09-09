import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';

/// Data-access for the per-repository worktree setup setting and the verdict of
/// the last setup run against each worktree. Hand-written SQL, no codegen.
class WorktreeSetupDao {
  WorktreeSetupDao(this._db);

  final AppDatabase _db;

  // --- the setting ----------------------------------------------------------

  /// The setup for [repositoryId] — **empty when there is no row**, which is
  /// the same answer as a row that asks for nothing. A caller that wants to
  /// know whether the user has ever configured this checkout asks
  /// [WorktreeSetup.isEmpty], not whether this returned null.
  WorktreeSetup get(String repositoryId) {
    final rows = _db.query(
      'SELECT command, copy_paths FROM worktree_setup WHERE repository_id = ?;',
      [repositoryId],
    );
    if (rows.isEmpty) return const WorktreeSetup();
    return WorktreeSetup.fromJson(
      rows.first['command'] as String?,
      rows.first['copy_paths'] as String?,
    );
  }

  /// Every checkout with something configured, by repository id.
  ///
  /// One query rather than one per checkout: the settings surface lists a whole
  /// workspace, and a row is three short strings.
  Map<String, WorktreeSetup> getAll() {
    final rows = _db.query(
      'SELECT repository_id, command, copy_paths FROM worktree_setup;',
    );
    return {
      for (final row in rows)
        row['repository_id'] as String: WorktreeSetup.fromJson(
          row['command'] as String?,
          row['copy_paths'] as String?,
        ),
    };
  }

  /// Stores [setup] for [repositoryId], or **deletes the row** when it asks for
  /// nothing.
  ///
  /// Emptying the fields and clearing the setting are the same intent, so they
  /// are the same write. Keeping an all-empty row would leave the settings list
  /// showing a configured checkout that does nothing.
  void save(String repositoryId, WorktreeSetup setup, DateTime now) {
    if (setup.isEmpty) {
      clear(repositoryId);
      return;
    }
    _db.execute(
      'INSERT INTO worktree_setup '
      '(repository_id, command, copy_paths, updated_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(repository_id) DO UPDATE SET '
      'command = excluded.command, copy_paths = excluded.copy_paths, '
      'updated_at = excluded.updated_at;',
      [
        repositoryId,
        setup.command.isEmpty ? null : setup.commandJson,
        setup.copyPathsJson,
        isoFromDate(now),
      ],
    );
  }

  void clear(String repositoryId) => _db.execute(
    'DELETE FROM worktree_setup WHERE repository_id = ?;',
    [repositoryId],
  );

  // --- what happened --------------------------------------------------------

  /// Records [report], replacing any earlier one for the same worktree.
  ///
  /// One row per worktree rather than a history: a worktree is set up once, and
  /// what a surface needs is the verdict for the directory in front of it. A
  /// re-run of the same setup is a correction of the same fact, not a second
  /// fact.
  void record(WorktreeSetupReport report) => _db.execute(
    'INSERT INTO worktree_setup_runs '
    '(repository_id, worktree_path, environment_id, ran_at, verdict, detail) '
    'VALUES (?, ?, ?, ?, ?, ?) '
    'ON CONFLICT(repository_id, worktree_path) DO UPDATE SET '
    'environment_id = excluded.environment_id, ran_at = excluded.ran_at, '
    'verdict = excluded.verdict, detail = excluded.detail;',
    [
      report.repositoryId,
      report.worktreePath,
      report.environmentId,
      isoFromDate(report.ranAt),
      report.verdict.name,
      report.toJsonString(),
    ],
  );

  /// The last setup of [worktree], or null when none was ever recorded.
  ///
  /// Null means **not recorded**, and a surface must say that rather than
  /// "fine": a worktree made before this feature existed, one whose repository
  /// has no setting, and one whose setup was never attempted are all this
  /// answer.
  WorktreeSetupReport? lastRun(String repositoryId, EnvironmentPath worktree) {
    final rows = _db.query(
      'SELECT * FROM worktree_setup_runs '
      'WHERE repository_id = ? AND worktree_path = ?;',
      [repositoryId, worktree.path],
    );
    return rows.isEmpty ? null : _report(rows.first);
  }

  /// Every recorded run for [repositoryId], newest first.
  List<WorktreeSetupReport> runsFor(String repositoryId) {
    final rows = _db.query(
      'SELECT * FROM worktree_setup_runs WHERE repository_id = ? '
      'ORDER BY ran_at DESC;',
      [repositoryId],
    );
    return rows.map(_report).toList();
  }

  WorktreeSetupReport _report(Map<String, Object?> row) =>
      WorktreeSetupReport.fromStored(
        repositoryId: row['repository_id'] as String,
        worktreePath: row['worktree_path'] as String,
        environmentId: row['environment_id'] as String,
        ranAt: dateFromIso(row['ran_at']),
        detail: row['detail'] as String,
      );
}
