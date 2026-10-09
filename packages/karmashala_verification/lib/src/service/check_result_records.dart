import '../domain/check_results.dart';
import '../domain/code_identity.dart';
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
    this.identity,
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

  /// The code the reading was taken on, or null for an older row.
  final CodeIdentity? identity;

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
      if (identity != null) 'code': identity!.label,
      'summary': results.summary,
      ...all,
      if (all.containsKey('diagnostics')) 'diagnostics': capped('diagnostics'),
      // Every passing test is noise to an agent; the failures are the point.
      if (all.containsKey('tests'))
        'tests': [for (final t in results.failures.take(limit)) t.toJson()],
    };
  }
}

/// Where structured check results are kept.
abstract interface class CheckResultRecords {
  void record(RecordedCheckResults results);

  /// [sessionId]'s readings, oldest first.
  List<RecordedCheckResults> forSession(String sessionId);

  /// The newest reading of [checkName] in [repositoryId] before [before] that
  /// is not [excludingSessionId]'s — taken in [directory] when one is given,
  /// so one worktree's reading is never another's baseline.
  RecordedCheckResults? latestBefore({
    required String repositoryId,
    required String checkName,
    required DateTime before,
    String? directory,
    String? excludingSessionId,
  });
}

/// [path] as `check_results.directory` holds it: trimmed, without a trailing
/// separator, so one checkout written two ways is one directory.
String? checkResultDirectory(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final stripped = trimmed.replaceFirst(RegExp(r'[\\/]+$'), '');
  return stripped.isEmpty || stripped.endsWith(':') ? trimmed : stripped;
}

/// What a session's [current] reading of a check is compared with: the last
/// reading of that check in the same [directory] before the session started,
/// or — when nobody had measured it there — the session's own first reading,
/// in that directory when it has one. Null when there is neither, or the two
/// are not the same kind of output. The change's label names which it was.
CheckResultsChange? changeAgainstBaseline(
  CheckResultRecords records, {
  required String repositoryId,
  required String checkName,
  required CheckResults current,
  required DateTime sessionStartedAt,
  String? directory,
  String? sessionId,
}) {
  final where = checkResultDirectory(directory);
  var baseline = records.latestBefore(
    repositoryId: repositoryId,
    checkName: checkName,
    before: sessionStartedAt,
    directory: where,
    excludingSessionId: sessionId,
  );
  var label = where == null
      ? 'the last reading in this repository before this session started'
      : 'the last reading in $where before this session started';
  if (baseline == null && sessionId != null) {
    final own = records
        .forSession(sessionId)
        .where((r) => r.checkName == checkName)
        .toList();
    final here = where == null
        ? null
        : own
              .where((r) => checkResultDirectory(r.directory) == where)
              .firstOrNull;
    baseline = here ?? own.firstOrNull;
    label = baseline == null || baseline.directory == null
        ? "this session's first reading"
        : "this session's first reading in "
              '${checkResultDirectory(baseline.directory)}';
  }
  if (baseline == null) return null;
  if (baseline.results.format.isAnalyzer != current.format.isAnalyzer) {
    return null;
  }
  return compareCheckResults(
    baseline: baseline.results,
    current: current,
    baselineLabel: '$label (${baseline.recordedAt.toUtc().toIso8601String()})',
  );
}
