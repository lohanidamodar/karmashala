import 'dart:convert';

import 'package:karmashala_store/database.dart';

import '../domain/check_results.dart';
import '../service/check_result_records.dart';

/// The `check_results` table: one row per check per run whose output parsed.
class CheckResultDao implements CheckResultRecords {
  CheckResultDao(this._db);

  final AppDatabase _db;

  @override
  void record(RecordedCheckResults results) => _db.execute(
    'INSERT INTO check_results (verification_run_id, session_id, '
    'repository_id, directory, check_name, recorded_at, results) '
    'VALUES (?, ?, ?, ?, ?, ?, ?);',
    [
      results.verificationRunId,
      results.sessionId,
      results.repositoryId,
      results.directory,
      results.checkName,
      isoFromDate(results.recordedAt),
      jsonEncode(results.results.toJson()),
    ],
  );

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
    String? excludingSessionId,
  }) {
    final rows = _db.query(
      'SELECT * FROM check_results WHERE repository_id = ? AND check_name = ? '
      'AND recorded_at < ? AND (session_id IS NULL OR session_id IS NOT ?) '
      'ORDER BY recorded_at DESC, id DESC LIMIT 1;',
      [repositoryId, checkName, isoFromDate(before), excludingSessionId],
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
