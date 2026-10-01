import 'package:agent_cli/process.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart';

import 'checkout_reach.dart';
import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// `github_runs` and `github_run_log`: a session's checkout's GitHub Actions
/// runs, and a failed one's log, read through `gh` where the checkout lives.
/// Read-only: nothing here re-runs, cancels or comments.
class GitHubRunToolSet extends ServerToolSet {
  GitHubRunToolSet(this._context, {required CheckoutReach reach})
    : _reach = reach;

  final ServerToolContext _context;
  final CheckoutReach _reach;

  @override
  List<Map<String, Object?>> get schemas => gitHubRunToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => switch (tool) {
    'github_runs' => runTool(() async {
      final directory = _checkoutOf(arguments, callerSessionId);
      final all = arguments['allBranches'] == true;
      final branch = all
          ? null
          : _text(arguments['branch']) ??
                await _orNull(
                  () =>
                      _reach.ask(directory, (git, at) => git.currentBranch(at)),
                );
      final limit = switch (arguments['limit']) {
        final num n => n.toInt().clamp(1, 30),
        _ => 10,
      };
      final runs = await _reach
          .gitHubFor(directory)
          .listWorkflowRuns(directory, branch: branch, limit: limit);
      return <String, Object?>{
        'checkout': directory.path,
        'branch': branch ?? 'all branches',
        'runs': [
          for (final run in runs) {...run.toJson(), 'failed': run.failed},
        ],
      };
    }),
    'github_run_log' => runTool(() async {
      final directory = _checkoutOf(arguments, callerSessionId);
      final runId = switch (arguments['runId']) {
        final num n => n.toInt(),
        final String s => int.tryParse(s.trim()),
        _ => null,
      };
      if (runId == null) {
        throw ArgumentError('runId is required: github_runs lists them.');
      }
      final log = await _reach
          .gitHubFor(directory)
          .failedRunLog(directory, runId: runId);
      return <String, Object?>{...log.toJson(), 'bound': log.bound};
    }),
    _ => null,
  };

  /// The calling (or named) session's worktree, else its repository.
  EnvironmentPath _checkoutOf(
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    final sessionId = targetSessionOf(arguments, callerSessionId);
    final session = SessionDao(_context.database).getById(sessionId);
    if (session == null) throw StateError('No session with id $sessionId.');
    final repository = RepositoryDao(
      _context.database,
    ).getById(session.repositoryId);
    final directory = session.worktree ?? repository?.path;
    if (directory == null) {
      throw StateError('Session $sessionId has no checkout recorded.');
    }
    if (!_reach.answers(directory.environmentId)) {
      throw StateError(
        'This Karmashala server cannot run gh where that checkout lives.',
      );
    }
    return directory;
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static Future<T?> _orNull<T>(Future<T?> Function() probe) async {
    try {
      return await probe();
    } on Object {
      return null;
    }
  }
}

/// The schemas for [GitHubRunToolSet].
const List<Map<String, Object?>> gitHubRunToolSchemas = [
  {
    'name': 'github_runs',
    'description':
        'The newest GitHub Actions runs for a session\'s checkout, read '
        'through gh: workflow, title, status, conclusion, branch, event, url '
        'and run id. Defaults to the checkout\'s current branch — a pull '
        'request\'s Actions checks are runs on its head branch. Read-only; '
        'github_run_log reads a failed one\'s log.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Whose checkout. Defaults to the calling session.',
        },
        'branch': {
          'type': 'string',
          'description': 'Runs on this branch instead of the current one.',
        },
        'allBranches': {
          'type': 'boolean',
          'description': 'The repository\'s newest runs on any branch.',
        },
        'limit': {
          'type': 'number',
          'description': 'How many runs, 1–30. Default 10.',
        },
      },
    },
  },
  {
    'name': 'github_run_log',
    'description':
        'The failed steps\' log of one GitHub Actions run (gh run view '
        '--log-failed), bounded to its last ${WorkflowRunLog.maxLines} lines '
        'and 32 KB, with every ##[error] line from the whole log. Lines read '
        '"job | step | text". Read-only: nothing is re-run.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'runId': {
          'type': 'number',
          'description': 'The run id from github_runs.',
        },
        'sessionId': {
          'type': 'string',
          'description': 'Whose checkout. Defaults to the calling session.',
        },
      },
      'required': ['runId'],
    },
  },
];
