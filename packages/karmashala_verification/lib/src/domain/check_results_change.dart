import 'check_results.dart';

/// What a session changed in one check's results, against a [baseline]
/// reading of the same check in the same repository.
class CheckResultsChange {
  const CheckResultsChange({
    required this.baselineLabel,
    required this.addedIssues,
    required this.resolvedIssues,
    required this.brokenTests,
    required this.fixedTests,
  });

  /// Which earlier reading this is against, in words.
  final String baselineLabel;
  final List<AnalyzerDiagnostic> addedIssues;
  final List<AnalyzerDiagnostic> resolvedIssues;

  /// Failing now and not failing in the baseline.
  final List<TestCaseResult> brokenTests;

  /// Failing in the baseline and not now — passing, skipped, or gone.
  final List<TestCaseResult> fixedTests;

  bool get isEmpty =>
      addedIssues.isEmpty &&
      resolvedIssues.isEmpty &&
      brokenTests.isEmpty &&
      fixedTests.isEmpty;

  String get summary {
    if (isEmpty) return 'no change against $baselineLabel';
    final errors = addedIssues
        .where((d) => d.severity == DiagnosticSeverity.error)
        .length;
    final parts = [
      if (addedIssues.isNotEmpty)
        'added ${_plural(addedIssues.length, 'issue')}'
            '${errors == 0 ? '' : ' ($errors error${errors == 1 ? '' : 's'})'}',
      if (resolvedIssues.isNotEmpty) 'resolved ${resolvedIssues.length}',
      if (brokenTests.isNotEmpty)
        'broke ${_plural(brokenTests.length, 'test')}',
      if (fixedTests.isNotEmpty) 'fixed ${fixedTests.length}',
    ];
    return '${parts.join(', ')} against $baselineLabel';
  }

  Map<String, Object?> toJson({int limit = 50}) => {
    'baseline': baselineLabel,
    'summary': summary,
    'addedIssues': addedIssues.length,
    'resolvedIssues': resolvedIssues.length,
    'brokenTests': brokenTests.length,
    'fixedTests': fixedTests.length,
    'added': [for (final d in addedIssues.take(limit)) d.toJson()],
    'resolved': [for (final d in resolvedIssues.take(limit)) d.toJson()],
    'broken': [for (final t in brokenTests.take(limit)) t.toJson()],
    'fixed': [for (final t in fixedTests.take(limit)) t.toJson()],
  };
}

/// [current] against [baseline]. Diagnostics compare by [AnalyzerDiagnostic.key]
/// as a multiset, so a second copy of a known issue still counts as added.
CheckResultsChange compareCheckResults({
  required CheckResults baseline,
  required CheckResults current,
  required String baselineLabel,
}) {
  final before = <String, int>{};
  for (final d in baseline.diagnostics) {
    before[d.key] = (before[d.key] ?? 0) + 1;
  }
  final added = <AnalyzerDiagnostic>[];
  for (final d in current.diagnostics) {
    final left = before[d.key] ?? 0;
    if (left > 0) {
      before[d.key] = left - 1;
    } else {
      added.add(d);
    }
  }
  final now = <String, int>{};
  for (final d in current.diagnostics) {
    now[d.key] = (now[d.key] ?? 0) + 1;
  }
  final resolved = <AnalyzerDiagnostic>[];
  for (final d in baseline.diagnostics) {
    final left = now[d.key] ?? 0;
    if (left > 0) {
      now[d.key] = left - 1;
    } else {
      resolved.add(d);
    }
  }
  final failedBefore = {for (final t in baseline.failures) t.key};
  final failedNow = {for (final t in current.failures) t.key};
  return CheckResultsChange(
    baselineLabel: baselineLabel,
    addedIssues: added,
    resolvedIssues: resolved,
    brokenTests: [
      for (final t in current.failures)
        if (!failedBefore.contains(t.key)) t,
    ],
    fixedTests: [
      for (final t in baseline.failures)
        if (!failedNow.contains(t.key)) t,
    ],
  );
}

String _plural(int count, String word) =>
    '$count $word${count == 1 ? '' : 's'}';
