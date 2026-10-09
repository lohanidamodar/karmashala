import 'package:karmashala_verification/check_results.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/verification.dart';

import 'project_check_runner.dart';

/// What `checks_run` answers an agent: the batch's verdict and each check,
/// or that nothing was checked. Never a claim that unchecked work passes.
String sessionChecksReport(SessionChecks? result) {
  if (result == null) {
    return 'NOTHING WAS CHECKED: this session\'s repository has no project '
        'checks. The user adds them in Settings → Checkpoints and '
        'automations → '
        'Verification and project checks. Nothing here claims the work '
        'passes.';
  }
  final run = result.run;
  return [
    '${_word(run.verdict ?? VerificationVerdict.inconclusive)} — '
        '${run.reason ?? ''} · verification_get ${run.id}',
    for (final check in result.checks) ...[
      '  ${_checkWord(check)} ${check.name} (${check.command.join(' ')})'
          '${check.refusal == null ? '' : ' — ${check.refusal}'}',
      if (check.resultsLine case final line?) '    $line',
      ..._changeLines(check),
    ],
    if (run.identity case final code?)
      'Code checked: ${code.label} in ${code.path}'
          '${code.changedDuringRun ? ' — it changed while the checks ran' : ''}.'
    else
      'Which code was checked was not recorded: this checkout could not be '
          'read as a git repository.',
    if (result.checks.any((c) => c.results != null))
      'Structured results: checks_results.',
  ].join('\n');
}

/// What the session broke or added, named — up to [limit] of each.
Iterable<String> _changeLines(CommandCheck check, {int limit = 10}) sync* {
  final change = check.change;
  if (change == null) {
    // No baseline yet: what is wrong now is the most useful thing to name.
    final results = check.results;
    if (results == null) return;
    for (final issue
        in results.diagnostics
            .where((d) => d.severity == DiagnosticSeverity.error)
            .take(limit)) {
      yield '    ${issue.listing}';
    }
    for (final test in results.failures.take(limit)) {
      yield '    failing: ${test.listing}';
    }
    return;
  }
  for (final issue in change.addedIssues.take(limit)) {
    yield '    + ${issue.listing}';
  }
  if (change.addedIssues.length > limit) {
    yield '    … and ${change.addedIssues.length - limit} more added issues';
  }
  for (final test in change.brokenTests.take(limit)) {
    yield '    broke: ${test.listing}'
        '${test.error == null ? '' : ' — ${test.error!.split('\n').first}'}';
  }
  if (change.brokenTests.length > limit) {
    yield '    … and ${change.brokenTests.length - limit} more broken tests';
  }
}

String _checkWord(CommandCheck check) =>
    check.refusal != null || check.exitCode == null
    ? 'INCONCLUSIVE'
    : check.exitCode == 0
    ? 'PASS'
    : 'FAIL (exit ${check.exitCode})';

String _word(VerificationVerdict verdict) => switch (verdict) {
  VerificationVerdict.pass => 'PASS',
  VerificationVerdict.fail => 'FAIL',
  VerificationVerdict.inconclusive => 'INCONCLUSIVE',
};

/// What `checks_results` answers: each check's newest structured reading in
/// the session, and what it changed against that check's baseline.
Object sessionCheckResultsReport(
  List<({RecordedCheckResults latest, CheckResultsChange? change})> readings, {
  int limit = 50,
  List<CodeFreshness>? freshness,
}) {
  if (readings.isEmpty) {
    return 'NOTHING RECORDED: no check in this session printed output '
        'Karmashala could read as analyzer diagnostics or test results. Run '
        'checks_run; a check reads best as `dart analyze --format=machine` or '
        '`flutter test --machine`.';
  }
  return {
    'baselineRule':
        'Each check is compared with the last reading of it in this '
        'repository before the session started; failing that, with the '
        "session's own first reading.",
    'freshnessRule':
        'fresh: the checkout is still the code the reading was taken on. '
        'stale: it changed since (or while it ran) — run checks_run again '
        'before relying on it. unknown: an older reading, or a checkout that '
        'cannot be read now.',
    'checks': [
      for (final (i, reading) in readings.indexed)
        {
          ...reading.latest.toJson(limit: limit),
          'identity': reading.latest.identity?.toSummaryJson(),
          'freshness':
              (freshness == null || i >= freshness.length
                      ? CodeFreshness.notRecorded
                      : freshness[i])
                  .toJson(),
          'change': reading.change?.toJson(limit: limit),
        },
    ],
  };
}
