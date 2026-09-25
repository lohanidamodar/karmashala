import 'package:karmashala_automations/check_runner.dart';
import 'package:riverpod/riverpod.dart';

import 'automation_check_runner.dart';

/// `checks_run`: a session's checkout's project checks, run by the app on
/// demand — where there is no session host, or for a checkout the host
/// forwards because it cannot run commands there.
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
    return sessionChecksReport(
      await _container
          .read(automationCheckRunnerProvider)
          .runForSession(sessionId),
    );
  }
}

const List<Map<String, Object?>> projectCheckToolSchemas = [
  {
    'name': 'checks_run',
    'description':
        'Run the project checks the user configured for a session\'s '
        'repository (tests, analyze, lint — whatever they added), in sessions '
        'Karmashala owns (watchable from the app) in the directory that '
        'session works in, one after another, and '
        'WAIT for them. The batch is recorded against the session as ONE '
        'verification run whose verdict is the worst of its checks — '
        'Karmashala\'s own reading, never your claim — readable with '
        'verification_get. Use it before saying work is done. A check that is '
        'closed by hand, or that could not start, is INCONCLUSIVE, '
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
