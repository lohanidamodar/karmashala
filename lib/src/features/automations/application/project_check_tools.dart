import 'package:riverpod/riverpod.dart';

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
    final outcomes = await _container
        .read(automationCheckRunnerProvider)
        .runForSession(sessionId);
    if (outcomes.isEmpty) {
      return 'NOTHING WAS CHECKED: this session\'s repository has no project '
          'checks. The user adds them in Settings → Automations → '
          'Verification and project checks. Nothing here claims the work '
          'passes.';
    }
    return [
      for (final outcome in outcomes)
        '${_word(outcome.verdict)} ${outcome.check.name} '
            '(${outcome.check.command.join(' ')})'
            '${outcome.reason.isEmpty ? '' : ' — ${outcome.reason}'}'
            '${outcome.verificationRunId == null ? '' : ' · verification_get ${outcome.verificationRunId}'}',
    ].join('\n');
  }

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
        'WAIT for them. Each exit code is recorded against the session as '
        'Karmashala\'s own reading, never as your claim, and is readable with '
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
