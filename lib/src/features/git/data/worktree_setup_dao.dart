import 'dart:convert';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';

/// Data-access for the per-repository worktree setup setting and the verdict of
/// the last setup run against each worktree. Hand-written SQL, no codegen.
class WorktreeSetupDao {
  WorktreeSetupDao(this._db);

  final AppDatabase _db;

  // --- the setting ----------------------------------------------------------

  /// The setup for [repositoryId] — empty when there is no row, which is the
  /// same answer as a row that asks for nothing.
  WorktreeSetup get(String repositoryId) {
    final rows = _db.query(
      'SELECT command, copy_paths FROM worktree_setup WHERE repository_id = ?;',
      [repositoryId],
    );
    if (rows.isEmpty) return const WorktreeSetup();
    return WorktreeSetup.fromJson(
      rows.first['command'] as String?,
      rows.first['copy_paths'] as String?,
    ).copyWith(startAgentBeforeSetup: !_waiting().contains(repositoryId));
  }

  /// Every checkout with something configured, by repository id — one query,
  /// because the settings surface lists a whole workspace.
  Map<String, WorktreeSetup> getAll() {
    final rows = _db.query(
      'SELECT repository_id, command, copy_paths FROM worktree_setup;',
    );
    final waiting = _waiting();
    return {
      for (final row in rows)
        row['repository_id'] as String:
            WorktreeSetup.fromJson(
              row['command'] as String?,
              row['copy_paths'] as String?,
            ).copyWith(
              startAgentBeforeSetup: !waiting.contains(row['repository_id']),
            ),
    };
  }

  // The agent-timing choice lives in `app_metadata`, not a column: it needed
  // no migration, and an older build reading the table simply ignores it.
  static const String _waitingKey = 'worktree_setup.agent_waits.v1';

  /// The checkouts whose agent waits for the setup command to exit.
  Set<String> _waiting() {
    final raw = _db.readMetadata(_waitingKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const {};
      return {
        for (final id in decoded)
          if (id is String) id,
      };
    } on FormatException {
      return const {};
    }
  }

  void _setWaiting(String repositoryId, bool waits) {
    final current = _waiting();
    if (current.contains(repositoryId) == waits) return;
    final next = {...current};
    waits ? next.add(repositoryId) : next.remove(repositoryId);
    _db.writeMetadata(_waitingKey, jsonEncode(next.toList()..sort()));
  }

  /// Stores [setup] for [repositoryId], or deletes the row when it asks for
  /// nothing: emptying the fields and clearing the setting are one intent.
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
    _setWaiting(repositoryId, !setup.startAgentBeforeSetup);
  }

  void clear(String repositoryId) {
    _db.execute('DELETE FROM worktree_setup WHERE repository_id = ?;', [
      repositoryId,
    ]);
    _setWaiting(repositoryId, false);
  }

  // --- what happened --------------------------------------------------------

  /// Records [report], replacing any earlier one for the same worktree — one
  /// row per worktree, because a re-run corrects the same fact.
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

  /// The last setup of [worktree], or null when none was recorded — which a
  /// surface must say rather than "fine".
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

  /// The newest [limit] runs across every checkout — including those with no
  /// setup, whose row is only the creation's stages.
  List<WorktreeSetupReport> recentRuns({int limit = 8}) => _db
      .query(
        'SELECT * FROM worktree_setup_runs ORDER BY ran_at DESC LIMIT ?;',
        [limit],
      )
      .map(_report)
      .toList();

  WorktreeSetupReport _report(Map<String, Object?> row) =>
      WorktreeSetupReport.fromStored(
        repositoryId: row['repository_id'] as String,
        worktreePath: row['worktree_path'] as String,
        environmentId: row['environment_id'] as String,
        ranAt: dateFromIso(row['ran_at']),
        detail: row['detail'] as String,
      );
}
