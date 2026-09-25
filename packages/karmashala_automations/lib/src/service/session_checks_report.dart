import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/verification.dart';

import 'project_check_runner.dart';

/// What `checks_run` answers an agent: the batch's verdict and each check,
/// or that nothing was checked. Never a claim that unchecked work passes.
String sessionChecksReport(SessionChecks? result) {
  if (result == null) {
    return 'NOTHING WAS CHECKED: this session\'s repository has no project '
        'checks. The user adds them in Settings → Automations → '
        'Verification and project checks. Nothing here claims the work '
        'passes.';
  }
  final run = result.run;
  return [
    '${_word(run.verdict ?? VerificationVerdict.inconclusive)} — '
        '${run.reason ?? ''} · verification_get ${run.id}',
    for (final check in result.checks)
      '  ${_checkWord(check)} ${check.name} (${check.command.join(' ')})'
          '${check.refusal == null ? '' : ' — ${check.refusal}'}',
  ].join('\n');
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
