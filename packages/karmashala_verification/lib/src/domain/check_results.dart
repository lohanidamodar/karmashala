/// How bad one analyzer diagnostic is, in the analyzer's own three words.
enum DiagnosticSeverity {
  error,
  warning,
  info;

  static DiagnosticSeverity? parse(String value) =>
      switch (value.trim().toLowerCase()) {
        'error' => DiagnosticSeverity.error,
        'warning' => DiagnosticSeverity.warning,
        'info' || 'lint' || 'hint' => DiagnosticSeverity.info,
        _ => null,
      };
}

/// One analyzer diagnostic. [file] is relative to the checkout when the parser
/// was told where that is, so two worktrees of one repository compare.
class AnalyzerDiagnostic {
  const AnalyzerDiagnostic({
    required this.severity,
    required this.code,
    required this.file,
    required this.line,
    required this.column,
    required this.message,
    this.type,
  });

  final DiagnosticSeverity severity;

  /// `COMPILE_TIME_ERROR`, `STATIC_WARNING`, `LINT` — only the machine format says.
  final String? type;
  final String code;
  final String file;
  final int line;
  final int column;
  final String message;

  /// Without the line: an edit above a diagnostic moves it without changing it.
  String get key => '${severity.name}|$code|$file|$message';

  String get listing =>
      '${severity.name} $file:$line:$column $code — $message';

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    if (type != null) 'type': type,
    'code': code,
    'file': file,
    'line': line,
    'column': column,
    'message': message,
  };

  static AnalyzerDiagnostic? fromJson(Object? json) {
    if (json is! Map) return null;
    final severity = DiagnosticSeverity.parse('${json['severity']}');
    if (severity == null) return null;
    return AnalyzerDiagnostic(
      severity: severity,
      type: json['type'] as String?,
      code: '${json['code'] ?? ''}',
      file: '${json['file'] ?? ''}',
      line: (json['line'] as num?)?.toInt() ?? 0,
      column: (json['column'] as num?)?.toInt() ?? 0,
      message: '${json['message'] ?? ''}',
    );
  }
}

enum TestOutcome { passed, failed, skipped }

/// One test as the runner reported it. Human output names only the failures,
/// so a passed test may be absent rather than listed.
class TestCaseResult {
  const TestCaseResult({
    required this.suite,
    required this.name,
    required this.outcome,
    this.error,
  });

  final String suite;
  final String name;
  final TestOutcome outcome;

  /// The first error it reported, cut short — the full text stays in the output.
  final String? error;

  String get key => '$suite|$name';

  String get listing => suite.isEmpty ? name : '$suite: $name';

  Map<String, Object?> toJson() => {
    'suite': suite,
    'name': name,
    'outcome': outcome.name,
    if (error != null) 'error': error,
  };

  static TestCaseResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final outcome = TestOutcome.values
        .where((o) => o.name == json['outcome'])
        .firstOrNull;
    if (outcome == null) return null;
    return TestCaseResult(
      suite: '${json['suite'] ?? ''}',
      name: '${json['name'] ?? ''}',
      outcome: outcome,
      error: json['error'] as String?,
    );
  }
}

/// Which output a parse recognised; the structure is only as complete as it.
enum CheckOutputFormat {
  analyzerMachine,
  analyzerText,
  testJson,
  testCompact;

  bool get isAnalyzer => this == analyzerMachine || this == analyzerText;
}

/// What one check's output said, as data: its diagnostics or its tests.
class CheckResults {
  const CheckResults({
    required this.format,
    this.diagnostics = const [],
    this.tests = const [],
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.partial = false,
  });

  final CheckOutputFormat format;
  final List<AnalyzerDiagnostic> diagnostics;

  /// Every test for JSON output; only the failures for compact output.
  final List<TestCaseResult> tests;
  final int passed;
  final int failed;
  final int skipped;

  /// The run never said it was done, or its start was lost: counts are a floor.
  final bool partial;

  int count(DiagnosticSeverity severity) =>
      diagnostics.where((d) => d.severity == severity).length;

  Iterable<TestCaseResult> get failures =>
      tests.where((t) => t.outcome == TestOutcome.failed);

  String get summary {
    final text = format.isAnalyzer
        ? (diagnostics.isEmpty
              ? 'no issues'
              : [
                  for (final severity in DiagnosticSeverity.values)
                    if (count(severity) > 0)
                      _plural(count(severity), severity.name),
                ].join(', '))
        : [
            '$passed passed',
            '$failed failed',
            if (skipped > 0) '$skipped skipped',
          ].join(', ');
    return partial ? '$text (partial output)' : text;
  }

  Map<String, Object?> toJson() => {
    'format': format.name,
    if (format.isAnalyzer)
      'diagnostics': [for (final d in diagnostics) d.toJson()]
    else ...{
      'passed': passed,
      'failed': failed,
      'skipped': skipped,
      'tests': [for (final t in tests) t.toJson()],
    },
    if (partial) 'partial': true,
  };

  static CheckResults? fromJson(Object? json) {
    if (json is! Map) return null;
    final format = CheckOutputFormat.values
        .where((f) => f.name == json['format'])
        .firstOrNull;
    if (format == null) return null;
    return CheckResults(
      format: format,
      diagnostics: [
        for (final d in (json['diagnostics'] as List?) ?? const [])
          ?AnalyzerDiagnostic.fromJson(d),
      ],
      tests: [
        for (final t in (json['tests'] as List?) ?? const [])
          ?TestCaseResult.fromJson(t),
      ],
      passed: (json['passed'] as num?)?.toInt() ?? 0,
      failed: (json['failed'] as num?)?.toInt() ?? 0,
      skipped: (json['skipped'] as num?)?.toInt() ?? 0,
      partial: json['partial'] == true,
    );
  }
}

String _plural(int count, String word) =>
    '$count $word${count == 1 ? '' : 's'}';
