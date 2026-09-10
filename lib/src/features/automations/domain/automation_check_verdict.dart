import '../../verification/domain/verification_run.dart';

/// What one project check said about the work a run left behind. [name] and
/// [command] are copied off the check so a verdict outlives its editing.
class AutomationCheckVerdict {
  const AutomationCheckVerdict({
    required this.runId,
    required this.ordinal,
    required this.name,
    required this.command,
    required this.verdict,
    required this.reason,
    required this.checkedAt,
    this.checkId,
    this.verificationRunId,
  });

  final String runId;

  /// Position in the checkout's own order, from 1 — the order they ran in.
  final int ordinal;

  /// The `project_checks` row this came from, or null once that row is gone.
  final String? checkId;

  final String name;
  final List<String> command;

  final VerificationVerdict verdict;

  /// Why the verdict is what it is, in words a person can act on. Never empty.
  final String reason;

  /// The `verification_runs` row this was recorded as, or null when nothing was
  /// run — an unreachable environment is a verdict with no command behind it.
  final String? verificationRunId;

  /// When this verdict was taken. Rendered with `describeAge`: a verdict with
  /// no age names a moment nobody can identify (§19).
  final DateTime checkedAt;

  bool get passed => verdict == VerificationVerdict.pass;

  @override
  String toString() =>
      'AutomationCheckVerdict($runId #$ordinal, $name, ${verdict.name})';
}

/// The run row's one line about its checks — never a pass for checks that never
/// ran. A null [observedAt] is "nothing has looked", not "there are none".
String describeAutomationChecks(
  List<AutomationCheckVerdict> checks, {
  required DateTime? observedAt,
}) {
  if (observedAt == null) {
    return 'The project checks have not been run for this occurrence, so '
        'whether the work still stands is unknown.';
  }
  if (checks.isEmpty) {
    return 'No project check is configured for this checkout, so nothing ran '
        'after the agent: whether the work still stands is unknown.';
  }
  final failed = checks.where((c) => c.verdict == VerificationVerdict.fail);
  final unknown = checks.where(
    (c) => c.verdict == VerificationVerdict.inconclusive,
  );
  final parts = <String>[
    if (failed.isNotEmpty) '${failed.length} failed',
    if (unknown.isNotEmpty) '${unknown.length} inconclusive',
  ];
  if (parts.isEmpty) return '${checks.length} check(s) passed.';
  return '${checks.length} check(s) ran: ${parts.join(', ')}.';
}
