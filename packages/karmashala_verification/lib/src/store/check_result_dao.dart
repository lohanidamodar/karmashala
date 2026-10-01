import 'dart:convert';

import 'package:karmashala_store/database.dart';

import '../domain/check_results.dart';
import '../service/check_result_records.dart';

/// The `check_results` table: one row per check per run whose output parsed.
///
/// Bounded: a row keeps diagnostics and failing tests only, and each
/// (repository, directory, check) keeps its newest [keepPerCheck] readings
/// plus the first reading of each session among them — the baseline
/// [changeAgainstBaseline] falls back to.
class CheckResultDao implements CheckResultRecords {
  CheckResultDao(this._db, {this.keepPerCheck = 20});

  final AppDatabase _db;
  final int keepPerCheck;

  @override
  void record(RecordedCheckResults results) {
    final directory = checkResultDirectory(results.directory);
    _db.transaction(() {
      _db.execute(
        'INSERT INTO check_results (verification_run_id, session_id, '
        'repository_id, directory, check_name, recorded_at, results) '
        'VALUES (?, ?, ?, ?, ?, ?, ?);',
        [
          results.verificationRunId,
          results.sessionId,
          results.repositoryId,
          directory,
          results.checkName,
          isoFromDate(results.recordedAt),
          jsonEncode(_stored(results.results).toJson()),
        ],
      );
      _trim(results.repositoryId, directory, results.checkName);
    });
  }

  /// Passing and skipped tests are never compared — only failures are — so
  /// they are counted, not kept.
  static CheckResults _stored(CheckResults results) => CheckResults(
    format: results.format,
    diagnostics: results.diagnostics,
    tests: results.failures.toList(),
    passed: results.passed,
    failed: results.failed,
    skipped: results.skipped,
    partial: results.partial,
  );

  void _trim(String repositoryId, String? directory, String checkName) {
    final rows = _db.query(
      'SELECT id, session_id FROM check_results WHERE repository_id = ? '
      'AND directory IS ? AND check_name = ? '
      'ORDER BY recorded_at DESC, id DESC;',
      [repositoryId, directory, checkName],
    );
    if (rows.length <= keepPerCheck) return;
    final keep = <int>{};
    final recentSessions = <String>{};
    for (final row in rows.take(keepPerCheck)) {
      keep.add(row['id']! as int);
      if (row['session_id'] case final String session) {
        recentSessions.add(session);
      }
    }
    // Oldest last, so the last id seen per session is its first reading.
    final firstOf = <String, int>{};
    for (final row in rows) {
      if (row['session_id'] case final String session
          when recentSessions.contains(session)) {
        firstOf[session] = row['id']! as int;
      }
    }
    keep.addAll(firstOf.values);
    for (final row in rows) {
      final id = row['id']! as int;
      if (!keep.contains(id)) {
        _db.execute('DELETE FROM check_results WHERE id = ?;', [id]);
      }
    }
  }

  @override
  List<RecordedCheckResults> forSession(String sessionId) => [
    for (final row in _db.query(
      'SELECT * FROM check_results WHERE session_id = ? '
      'ORDER BY recorded_at, id;',
      [sessionId],
    ))
      ?_fromRow(row),
  ];

  @override
  RecordedCheckResults? latestBefore({
    required String repositoryId,
    required String checkName,
    required DateTime before,
    String? directory,
    String? excludingSessionId,
  }) {
    final where = checkResultDirectory(directory);
    final rows = _db.query(
      'SELECT * FROM check_results WHERE repository_id = ? AND check_name = ? '
      'AND recorded_at < ? AND (session_id IS NULL OR session_id IS NOT ?) '
      '${where == null ? '' : 'AND directory = ? '}'
      'ORDER BY recorded_at DESC, id DESC LIMIT 1;',
      [
        repositoryId,
        checkName,
        isoFromDate(before),
        excludingSessionId,
        ?where,
      ],
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  RecordedCheckResults? _fromRow(Map<String, Object?> row) {
    final Object? decoded;
    try {
      decoded = jsonDecode(row['results']! as String);
    } on FormatException {
      return null;
    }
    final results = CheckResults.fromJson(decoded);
    if (results == null) return null;
    return RecordedCheckResults(
      id: row['id'] as int?,
      verificationRunId: row['verification_run_id'] as String?,
      sessionId: row['session_id'] as String?,
      repositoryId: row['repository_id']! as String,
      directory: row['directory'] as String?,
      checkName: row['check_name']! as String,
      recordedAt: dateFromIso(row['recorded_at']),
      results: results,
    );
  }
}
