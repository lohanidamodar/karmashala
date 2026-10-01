import 'dart:convert';

import 'check_results.dart';

/// Reads a check's output as analyzer diagnostics or test results: the
/// machine formats (`dart analyze --format=machine`, `flutter test --machine`,
/// `dart test --reporter json`) and, less completely, their human ones. Null
/// when the output is none of them — the exit code is then all there is.
///
/// [root] is the directory the check ran in; paths under it are made relative.
/// [columns] is the terminal width the output was wrapped at, if any.
/// [truncated] says the output's start was lost, so the result is partial.
CheckResults? parseCheckOutput(
  String output, {
  String? root,
  int? columns,
  bool truncated = false,
}) {
  final lines = terminalLines(output, columns: columns);
  final relative = _Relativizer(root);
  return _testJson(lines, relative, truncated) ??
      _analyzerMachine(lines, relative, truncated) ??
      _analyzerText(lines, relative, truncated) ??
      _testCompact(lines, truncated);
}

final RegExp _escapes = RegExp(
  r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B[@-Z\\-_]',
);
final RegExp _machineStart = RegExp(r'^(ERROR|WARNING|INFO)\|');

/// [text] as the lines a reader saw: escapes gone, a `\r` redraw kept as its
/// own line, and a line the terminal wrapped at [columns] joined back.
List<String> terminalLines(String text, {int? columns}) {
  final physical = <String>[
    for (final line in text.replaceAll(_escapes, '').split('\n'))
      for (final part in line.split('\r'))
        if (part.isNotEmpty) part,
  ];
  if (columns == null || columns <= 0) return physical;
  final joined = <String>[];
  var wrapping = false;
  for (final line in physical) {
    final startsRecord = line.startsWith('{') || _machineStart.hasMatch(line);
    if (wrapping && !startsRecord) {
      joined[joined.length - 1] += line;
    } else {
      joined.add(line);
    }
    wrapping = line.length == columns;
  }
  return joined;
}

CheckResults? _analyzerMachine(
  List<String> lines,
  _Relativizer relative,
  bool truncated,
) {
  var seen = false;
  final diagnostics = <AnalyzerDiagnostic>[];
  for (final line in lines) {
    if (!_machineStart.hasMatch(line)) continue;
    final fields = _splitMachine(line);
    if (fields.length < 8) continue;
    final severity = DiagnosticSeverity.parse(fields[0]);
    if (severity == null) continue;
    seen = true;
    diagnostics.add(
      AnalyzerDiagnostic(
        severity: severity,
        type: fields[1],
        code: fields[2].toLowerCase(),
        file: relative(fields[3]),
        line: int.tryParse(fields[4]) ?? 0,
        column: int.tryParse(fields[5]) ?? 0,
        message: fields.sublist(7).join('|'),
      ),
    );
  }
  if (!seen) return null;
  return CheckResults(
    format: CheckOutputFormat.analyzerMachine,
    diagnostics: diagnostics,
    partial: truncated,
  );
}

/// The machine format's fields: `|` separates, a backslash escapes the next
/// character.
List<String> _splitMachine(String line) {
  final fields = <String>[];
  final field = StringBuffer();
  var escaped = false;
  for (final unit in line.split('')) {
    if (escaped) {
      field.write(unit);
      escaped = false;
    } else if (unit == r'\') {
      escaped = true;
    } else if (unit == '|') {
      fields.add(field.toString());
      field.clear();
    } else {
      field.write(unit);
    }
  }
  fields.add(field.toString());
  return fields;
}

// `  error - lib/a.dart:3:5 - Message. - code` (dart analyze) and
// `  error • Message • lib/a.dart:3:5 • code` (flutter analyze).
final RegExp _dartText = RegExp(
  r'^\s*(error|warning|info|lint|hint) - (.+?):(\d+):(\d+) - (.+) - ([a-z0-9_]+)\s*$',
);
final RegExp _flutterText = RegExp(
  r'^\s*(error|warning|info|lint|hint) • (.+) • (.+?):(\d+):(\d+) • ([a-z0-9_]+)\s*$',
);
final RegExp _analyzerVerdict = RegExp(
  r'^\s*(No issues found!|\d+ issues? found\.)',
);

CheckResults? _analyzerText(
  List<String> lines,
  _Relativizer relative,
  bool truncated,
) {
  var seen = false;
  final diagnostics = <AnalyzerDiagnostic>[];
  for (final line in lines) {
    if (_analyzerVerdict.hasMatch(line)) {
      seen = true;
      continue;
    }
    final dart = _dartText.firstMatch(line);
    final flutter = dart == null ? _flutterText.firstMatch(line) : null;
    final match = dart ?? flutter;
    if (match == null) continue;
    final severity = DiagnosticSeverity.parse(match[1]!);
    if (severity == null) continue;
    seen = true;
    diagnostics.add(
      dart != null
          ? AnalyzerDiagnostic(
              severity: severity,
              file: relative(dart[2]!),
              line: int.parse(dart[3]!),
              column: int.parse(dart[4]!),
              message: dart[5]!,
              code: dart[6]!,
            )
          : AnalyzerDiagnostic(
              severity: severity,
              message: flutter![2]!,
              file: relative(flutter[3]!),
              line: int.parse(flutter[4]!),
              column: int.parse(flutter[5]!),
              code: flutter[6]!,
            ),
    );
  }
  if (!seen) return null;
  return CheckResults(
    format: CheckOutputFormat.analyzerText,
    diagnostics: diagnostics,
    partial: truncated,
  );
}

/// The JSON reporter's event stream. A line that does not decode is held and
/// retried with the next, which is how a line the terminal broke comes back.
CheckResults? _testJson(
  List<String> lines,
  _Relativizer relative,
  bool truncated,
) {
  final suites = <int, String>{};
  final started = <int, ({int suite, String name})>{};
  final errors = <int, String>{};
  final results = <TestCaseResult>[];
  var seen = false;
  var done = false;
  String? pending;
  for (final line in lines) {
    final candidate = pending == null ? line : '$pending$line';
    if (!candidate.startsWith('{')) {
      pending = null;
      continue;
    }
    final Object? event;
    try {
      event = jsonDecode(candidate);
    } on FormatException {
      pending = candidate.length > 1 << 20 ? null : candidate;
      continue;
    }
    pending = null;
    if (event is! Map || event['type'] is! String) continue;
    switch (event['type']) {
      case 'start':
        seen = true;
      case 'suite':
        final suite = event['suite'];
        if (suite is Map && suite['id'] is num) {
          suites[(suite['id'] as num).toInt()] = relative(
            '${suite['path'] ?? ''}',
          );
        }
      case 'testStart':
        final test = event['test'];
        if (test is Map && test['id'] is num) {
          seen = true;
          started[(test['id'] as num).toInt()] = (
            suite: (test['suiteID'] as num?)?.toInt() ?? -1,
            name: '${test['name'] ?? ''}',
          );
        }
      case 'error':
        final id = (event['testID'] as num?)?.toInt();
        if (id != null && !errors.containsKey(id)) {
          errors[id] = _clip('${event['error'] ?? ''}');
        }
      case 'testDone':
        final id = (event['testID'] as num?)?.toInt();
        final test = started[id];
        if (id == null || test == null) continue;
        final failed = event['result'] != 'success';
        // The runner's own "loading" tests are noise unless they failed.
        if (event['hidden'] == true && !failed) continue;
        results.add(
          TestCaseResult(
            suite: suites[test.suite] ?? '',
            name: test.name,
            outcome: failed
                ? TestOutcome.failed
                : event['skipped'] == true
                ? TestOutcome.skipped
                : TestOutcome.passed,
            error: failed ? errors[id] : null,
          ),
        );
      case 'done':
        done = true;
    }
  }
  if (!seen) return null;
  int countOf(TestOutcome outcome) =>
      results.where((r) => r.outcome == outcome).length;
  return CheckResults(
    format: CheckOutputFormat.testJson,
    tests: results,
    passed: countOf(TestOutcome.passed),
    failed: countOf(TestOutcome.failed),
    skipped: countOf(TestOutcome.skipped),
    partial: truncated || !done,
  );
}

// `00:04 +12 ~1 -2: test/a_test.dart: group test [E]` and the closing
// `00:09 +40 -2: Some tests failed.` of the compact and expanded reporters.
final RegExp _compactLine = RegExp(
  r'^\s*\d+:\d+ \+(\d+)(?: ~(\d+))?(?: -(\d+))?: (.*)$',
);
final RegExp _compactVerdict = RegExp(
  r'^(All tests passed!|Some tests failed\.|All tests skipped\.)',
);

CheckResults? _testCompact(List<String> lines, bool truncated) {
  var seen = false;
  var finished = false;
  var passed = 0;
  var skipped = 0;
  var failed = 0;
  final failures = <String, TestCaseResult>{};
  for (final line in lines) {
    final match = _compactLine.firstMatch(line);
    if (match == null) continue;
    seen = true;
    passed = int.parse(match[1]!);
    skipped = int.tryParse(match[2] ?? '') ?? 0;
    failed = int.tryParse(match[3] ?? '') ?? 0;
    final rest = match[4]!.trimRight();
    if (_compactVerdict.hasMatch(rest)) finished = true;
    if (!rest.endsWith(' [E]')) continue;
    final title = rest.substring(0, rest.length - 4);
    final split = title.indexOf('.dart: ');
    final suite = split < 0 ? '' : title.substring(0, split + 5);
    final name = split < 0 ? title : title.substring(split + 7);
    failures['$suite|$name'] = TestCaseResult(
      suite: suite,
      name: name,
      outcome: TestOutcome.failed,
    );
  }
  if (!seen) return null;
  return CheckResults(
    format: CheckOutputFormat.testCompact,
    tests: failures.values.toList(),
    passed: passed,
    failed: failed,
    skipped: skipped,
    partial: truncated || !finished,
  );
}

String _clip(String text) {
  final first = text.trim().split('\n').take(6).join('\n');
  return first.length <= 600 ? first : '${first.substring(0, 597)}…';
}

/// A path as it reads under [_root], forward-slashed; any other path as given.
class _Relativizer {
  _Relativizer(String? root)
    : _root = root == null || root.trim().isEmpty ? null : _normal(root);

  final String? _root;

  static String _normal(String path) {
    var normal = path.replaceAll(r'\', '/');
    if (normal.startsWith('file://')) normal = normal.substring(7);
    if (_driveUri.hasMatch(normal)) normal = normal.substring(1);
    while (normal.endsWith('/') && normal.length > 1) {
      normal = normal.substring(0, normal.length - 1);
    }
    return normal;
  }

  String call(String path) {
    final normal = _normal(path);
    final root = _root;
    if (root == null) return normal;
    // Without case: a Windows drive letter is spelled both ways.
    final under = normal.toLowerCase().startsWith('${root.toLowerCase()}/');
    return under ? normal.substring(root.length + 1) : normal;
  }
}

final RegExp _driveUri = RegExp(r'^/[A-Za-z]:/');
