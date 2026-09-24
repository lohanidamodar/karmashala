import 'package:riverpod/riverpod.dart';

import '../../verification/application/verification_service.dart';
import '../../verification/domain/verification_run.dart';
import 'automation_check_runner.dart';

/// `checks_run`: a session's checkout's project checks, run by the app on
/// demand, so "the tests pass" is an exit code Karmashala saw rather than a
/// sentence an agent wrote.
class ProjectCheckTools {
  ProjectCheckTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;
  final String? callerSessionId;

  static bool handles(String name) => name == 'checks_run';

  Future<Object?> call(String name, Map<String, dynamic> args) async {
    final sessionId = (args['sessionId'] as String?) ?? callerSessionId;
    if (sessionId == null) {
      throw ArgumentError(
        'Missing sessionId. Outside a session there is no checkout to check.',
      );
    }
    final result = await _container
        .read(automationCheckRunnerProvider)
        .runForSession(sessionId);
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

  static String _checkWord(CommandCheck check) =>
      check.refusal != null || check.exitCode == null
      ? 'INCONCLUSIVE'
      : check.exitCode == 0
      ? 'PASS'
      : 'FAIL (exit ${check.exitCode})';

  static String _word(VerificationVerdict verdict) => switch (verdict) {
    VerificationVerdict.pass => 'PASS',
    VerificationVerdict.fail => 'FAIL',
    VerificationVerdict.inconclusive => 'INCONCLUSIVE',
  };
}

const List<Map<String, Object?>> projectCheckToolSchemas = [
  {
    'name': 'checks_run',
    'description':
        'Run the project checks the user configured for a session\'s '
        'repository (tests, analyze, lint — whatever they added), in visible '
        'panes in the directory that session works in, one after another, and '
        'WAIT for them. The batch is recorded against the session as ONE '
        'verification run whose verdict is the worst of its checks — '
        'Karmashala\'s own reading, never your claim — readable with '
        'verification_get. Use it before saying work is done. A check whose '
        'pane is closed by hand, or that could not start, is INCONCLUSIVE, '
        'never a pass. Answers NOTHING WAS CHECKED when the repository has '
        'none.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Whose checkout to check. Defaults to yours.',
        },
      },
    },
  },
];
