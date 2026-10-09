import '../mcp/tools/server_tool_set.dart';

/// `checks_run`: a session's project checks, run by the server — in sessions
/// it owns when the checkout is on this machine (a WSL distribution too, on a
/// Windows server), and as commands over its own connection when it is on an
/// SSH box (slice 3a). Anything else is refused in words (slice 5b: nothing
/// is handed to an app). `checks_results` reads what those runs parsed.
class ChecksToolSet extends ServerToolSet {
  const ChecksToolSet(this._run);

  /// The daemon's own runner: null when the checkout is not this machine's.
  final Future<Object?>? Function(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  )
  _run;

  @override
  List<Map<String, Object?>> get schemas => checksToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    final sessionId = (arguments['sessionId'] as String?) ?? callerSessionId;
    if (sessionId == null) {
      return Future.error(
        ArgumentError(
          'Missing sessionId. Outside a session there is no checkout to check.',
        ),
      );
    }
    return _run(tool, arguments, callerSessionId) ??
        Future.error(
          StateError(
            'NOTHING WAS CHECKED: session $sessionId is not one this server '
            'knows, or its checkout is somewhere it cannot run commands — not '
            'this machine, a WSL distribution of a Windows server, or an SSH '
            'box it reaches.',
          ),
        );
  }
}

const List<Map<String, Object?>> checksToolSchemas = [
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
        'none. A check whose output is analyzer diagnostics or test results '
        '(best as `dart analyze --format=machine` or `flutter test '
        '--machine`) also reports them as data, and what this session '
        'added or broke against a baseline.',
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
  {
    'name': 'checks_results',
    'description':
        'The structured results of a session\'s project checks, as recorded '
        'by its newest checks_run: per check, the analyzer diagnostics (file, '
        'line, code, message) or the failing tests, and what the session '
        'changed — issues added and resolved, tests broken and fixed — '
        'against the baseline: the last reading of that check in the '
        'repository before the session started, or else the session\'s own '
        'first reading. Runs nothing; run checks_run first for fresh results. '
        'A check whose output was neither format has none. Each reading '
        'carries the code it was taken on (identity) and its freshness '
        'against the checkout now: fresh, stale (the code changed since — run '
        'checks_run again) or unknown.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Whose results to read. Defaults to yours.',
        },
        'limit': {
          'type': 'number',
          'description': 'Most items listed per list (default 50).',
        },
      },
    },
  },
];
