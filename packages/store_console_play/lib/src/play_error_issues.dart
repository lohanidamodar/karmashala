import 'package:store_console/store_console.dart';

/// How far back the clusters are read.
const Duration errorIssueWindow = Duration(days: 28);

/// Clusters read per app, and how many of them get a sample report: each
/// sample is one more call per app per refresh.
const int errorIssueCount = 10;
const int errorSampleCount = 3;

/// The crash and ANR clusters on one page of `errorIssues:search`, most
/// reported first.
List<StoreErrorIssue> parseErrorIssues(Map<String, Object?> json) {
  final issues = <StoreErrorIssue>[];
  for (final issue in _maps(json['errorIssues'])) {
    final id = _lastSegment(issue['name']);
    final kind = switch (issue['type']) {
      'CRASH' => StoreErrorKind.crash,
      'ANR' => StoreErrorKind.anr,
      _ => null,
    };
    if (id == null || kind == null) continue;
    final uri = issue['issueUri'];
    issues.add(
      StoreErrorIssue(
        id: id,
        kind: kind,
        cause: _text(issue['cause']),
        location: _text(issue['location']),
        reportCount: _int(issue['errorReportCount']),
        distinctUsers: _int(issue['distinctUsers']),
        lastSeen: _time(issue['lastErrorReportTime']),
        firstVersionCode: _versionCode(issue['firstAppVersion']),
        lastVersionCode: _versionCode(issue['lastAppVersion']),
        consoleUrl: uri is String && uri.startsWith('https://') ? uri : null,
      ),
    );
  }
  // Sorted here too: the order asked for is a request, not a promise.
  issues.sort((a, b) => (b.reportCount ?? 0).compareTo(a.reportCount ?? 0));
  return issues;
}

/// [issue] with the first report on a page of `errorReports:search` as its
/// sample; [issue] itself when the page has none.
StoreErrorIssue withSampleReport(
  StoreErrorIssue issue,
  Map<String, Object?> json,
) {
  final report = _maps(json['errorReports']).firstOrNull;
  final text = report?['reportText'];
  if (report == null || text is! String || text.trim().isEmpty) return issue;
  return StoreErrorIssue(
    id: issue.id,
    kind: issue.kind,
    cause: issue.cause,
    location: issue.location,
    reportCount: issue.reportCount,
    distinctUsers: issue.distinctUsers,
    lastSeen: issue.lastSeen,
    firstVersionCode: issue.firstVersionCode,
    lastVersionCode: issue.lastVersionCode,
    consoleUrl: issue.consoleUrl,
    sampleTrace: text.length > StoreErrorIssue.sampleTraceLimit
        ? '${text.substring(0, StoreErrorIssue.sampleTraceLimit)}\n…'
        : text,
    sampleAt: _time(report['eventTime']),
    sampleVersionCode: _versionCode(report['appVersion']),
  );
}

String? _lastSegment(Object? name) {
  if (name is! String || name.isEmpty) return null;
  final id = name.substring(name.lastIndexOf('/') + 1);
  return id.isEmpty ? null : id;
}

String _text(Object? value) => value is String ? value.trim() : '';

int? _int(Object? value) => switch (value) {
  final int number => number,
  final String text => int.tryParse(text),
  _ => null,
};

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String? _versionCode(Object? version) {
  final code = version is Map ? version['versionCode'] : null;
  return switch (code) {
    final String text when text.isNotEmpty => text,
    final int number => '$number',
    _ => null,
  };
}

Iterable<Map<Object?, Object?>> _maps(Object? list) =>
    list is List ? list.whereType<Map<Object?, Object?>>() : const [];
