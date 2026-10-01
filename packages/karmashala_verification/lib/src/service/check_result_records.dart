import '../domain/check_results.dart';
import '../domain/check_results_change.dart';

/// One check's structured results as recorded: whose, where, and when.
class RecordedCheckResults {
  const RecordedCheckResults({
    required this.repositoryId,
    required this.checkName,
    required this.recordedAt,
    required this.results,
    this.id,
    this.verificationRunId,
    this.sessionId,
    this.directory,
  });

  final int? id;
  final String? verificationRunId;
  final String? sessionId;
  final String repositoryId;

  /// The directory the check ran in — a worktree or the checkout itself.
  final String? directory;
  final String checkName;
  final DateTime recordedAt;
  final CheckResults results;

  Map<String, Object?> toJson({int limit = 50}) {
    final all = results.toJson();
    List<Object?> capped(String key) =>
        ((all[key] as List?) ?? const []).take(limit).toList();
    return {
      'check': checkName,
      'recordedAt': recordedAt.toIso8601String(),
      if (verificationRunId != null) 'verificationRunId': verificationRunId,
      if (sessionId != null) 'sessionId': sessionId,
      if (directory != null) 'directory': directory,
      'summary': results.summary,
      ...all,
      if (all.containsKey('diagnostics')) 'diagnostics': capped('diagnostics'),
      // Every passing test is noise to an agent; the failures are the point.
      if (all.containsKey('tests'))
        'tests': [
          for (final t in results.failures.take(limit)) t.toJson(),
        ],
    };
  }
}

/// Where structured check results are kept.
abstract interface class CheckResultRecords {
  void record(RecordedCheckResults results);

  /// [sessionId]'s readings, oldest first.
  List<RecordedCheckResults> forSession(String sessionId);

  /// The newest reading of [checkName] in [repositoryId] before [before] that
  /// is not [excludingSessionId]'s.
  RecordedCheckResults? latestBefore({
    required String repositoryId,
    required String checkName,
    required DateTime before,
    String? excludingSessionId,
  });
}

/// What a session's [current] reading of a check is compared with: the last
/// reading of that check in the repository before the session started, or —
/// when nobody had measured it then — the session's own first reading.
/// Null when there is neither, or the two are not the same kind of output.
CheckResultsChange? changeAgainstBaseline(
  CheckResultRecords records, {
  required String repositoryId,
  required String checkName,
  required CheckResults current,
  required DateTime sessionStartedAt,
  String? sessionId,
}) {
  var baseline = records.latestBefore(
    repositoryId: repositoryId,
    checkName: checkName,
    before: sessionStartedAt,
    excludingSessionId: sessionId,
  );
  var label = 'the last reading before this session started';
  if (baseline == null && sessionId != null) {
    baseline = records
        .forSession(sessionId)
        .where((r) => r.checkName == checkName)
        .firstOrNull;
    label = "this session's first reading";
  }
  if (baseline == null) return null;
  if (baseline.results.format.isAnalyzer != current.format.isAnalyzer) {
    return null;
  }
  return compareCheckResults(
    baseline: baseline.results,
    current: current,
    baselineLabel:
        '$label (${baseline.recordedAt.toUtc().toIso8601String()})',
  );
}
