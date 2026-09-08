import 'dart:convert';

import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import '../domain/project_check.dart';

/// The per-checkout verification the unattended gate refuses without: whether
/// it is on, and what it runs.
class ProjectCheckDao {
  ProjectCheckDao(this._db);

  final AppDatabase _db;

  // --- the switch -----------------------------------------------------------

  /// Whether verification is on for [repositoryId].
  ///
  /// **No row means off.** A checkout nobody has configured has not opted in,
  /// and reading its silence as consent is exactly what the gate exists to
  /// stop. Not "unknown": absence here is a decision nobody made, and the safe
  /// reading of a decision nobody made is no.
  bool isVerificationEnabled(String repositoryId) {
    final rows = _db.query(
      'SELECT enabled FROM project_verification WHERE repository_id = ?;',
      [repositoryId],
    );
    return rows.isNotEmpty && boolFromInt(rows.first['enabled']);
  }

  void setVerificationEnabled(
    String repositoryId, {
    required bool enabled,
    required DateTime now,
  }) => _db.execute(
    'INSERT INTO project_verification (repository_id, enabled, updated_at) '
    'VALUES (?, ?, ?) ON CONFLICT(repository_id) DO UPDATE SET '
    'enabled = excluded.enabled, updated_at = excluded.updated_at;',
    [repositoryId, intFromBool(enabled), isoFromDate(now)],
  );

  /// Every checkout that has turned verification on.
  Set<String> verifiedRepositories() => {
    for (final row in _db.query(
      'SELECT repository_id FROM project_verification WHERE enabled = 1;',
    ))
      row['repository_id']! as String,
  };

  // --- the checks -----------------------------------------------------------

  void insert(ProjectCheck check) => _db.execute(
    'INSERT INTO project_checks (id, repository_id, name, command, created_at) '
    'VALUES (?, ?, ?, ?, ?);',
    [
      check.id,
      check.repositoryId,
      check.name,
      jsonEncode(check.command),
      isoFromDate(check.createdAt),
    ],
  );

  void delete(String id) =>
      _db.execute('DELETE FROM project_checks WHERE id = ?;', [id]);

  List<ProjectCheck> forRepository(String repositoryId) => _db
      .query(
        'SELECT * FROM project_checks WHERE repository_id = ? '
        'ORDER BY created_at, id;',
        [repositoryId],
      )
      .map(_check)
      .toList();

  /// How many checks [repositoryId] has. One query, because the gate asks this
  /// on every arm and every fire and never needs the commands themselves.
  int countFor(String repositoryId) {
    final rows = _db.query(
      'SELECT COUNT(*) AS n FROM project_checks WHERE repository_id = ?;',
      [repositoryId],
    );
    return rows.isEmpty ? 0 : (rows.first['n']! as int);
  }

  ProjectCheck _check(Map<String, Object?> row) => ProjectCheck(
    id: row['id']! as String,
    repositoryId: row['repository_id']! as String,
    name: row['name']! as String,
    command: _argv(row['command'] as String?),
    createdAt: dateFromIso(row['created_at']),
  );

  /// Forgiving in the way `WorktreeSetup.fromJson` is: a row this code did not
  /// write reads as no command rather than throwing, so one bad row cannot
  /// stop the whole list being read.
  static List<String> _argv(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final part in decoded)
          if (part is String && part.isNotEmpty) part,
      ];
    } on FormatException {
      return const [];
    }
  }
}
