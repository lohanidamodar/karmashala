import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:path/path.dart' as p;

import 'server_tool_context.dart';
import 'server_tool_set.dart';
import 'worktree_tool_set.dart';

/// **The checkouts a session spans, changed by the agent in it** —
/// `session_checkout_attach` and `session_checkout_detach`. The link is the
/// same row the app's repositories bar writes, through the data service, so
/// the bar shows the attach as it happens; the rule about which checkouts a
/// session may span is the server's (`SessionsHandler`): one project, unless
/// the session has none and runs in Scratch.
///
/// With `worktree`, the attach first makes one the way `worktree_create`
/// does — the same collisions refused in the same words — and links the new
/// checkout instead of the one named, so the work lands on a branch of the
/// session's own.
class SessionCheckoutToolSet extends ServerToolSet {
  SessionCheckoutToolSet(this._context, {required WorktreeToolSet worktrees})
    : _worktrees = worktrees;

  final ServerToolContext _context;
  final WorktreeToolSet _worktrees;

  @override
  List<Map<String, Object?>> get schemas => sessionCheckoutToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    try {
      return switch (tool) {
        'session_checkout_attach' => _attach(arguments, callerSessionId),
        'session_checkout_detach' => _detach(arguments, callerSessionId),
        _ => throw ArgumentError('Unknown tool: $tool'),
      };
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Session _session(Map<String, dynamic> args, String? callerSessionId) {
    final id = _text(args['sessionId']) ?? callerSessionId;
    if (id == null) {
      throw ArgumentError(
        'sessionId is required when the caller is not a session itself.',
      );
    }
    return SessionDao(_context.database).getById(id) ??
        (throw StateError(
          'No session with id $id. list_sessions has the ids.',
        ));
  }

  Repository _checkout(String? repositoryId) {
    final id = _text(repositoryId);
    if (id == null) {
      throw ArgumentError(
        'repositoryId is required. list_checkouts has the ids.',
      );
    }
    return RepositoryDao(_context.database).getById(id) ??
        (throw StateError('No checkout with id $id.'));
  }

  Future<Object?>? _attach(Map<String, dynamic> args, String? callerSessionId) {
    final session = _session(args, callerSessionId);
    final from = _checkout(args['repositoryId'] as String?);
    final worktree = args['worktree'];
    if (worktree != null && worktree is! Map) {
      throw ArgumentError(
        'worktree must be an object: {name, branch, baseRef}.',
      );
    }
    return runTool(() async {
      var checkout = from;
      Map<String, Object?>? made;
      if (worktree is Map) {
        final result = await _worktrees.call('worktree_create', {
          'repositoryId': from.id,
          'name': worktree['name'],
          'branch': worktree['branch'],
          'baseRef': ?worktree['baseRef'],
        }, callerSessionId);
        if (result is! Map<String, Object?>) {
          throw StateError(
            'The worktree could not be made from here; make it with '
            'worktree_create on a machine that reaches ${from.name}.',
          );
        }
        made = result;
        final id = result['repositoryId'];
        var recorded = id is String
            ? RepositoryDao(_context.database).getById(id)
            : null;
        // A worktree lands beside its checkout, which can be outside the
        // project's root — where a rescan never looks. The path and project
        // are both known here, so the row is written rather than hoped for.
        if (recorded == null && result['path'] is String) {
          final location = EnvironmentPath(
            environmentId: from.path.environmentId,
            path: result['path']! as String,
          );
          final rows = _context.write(
            CheckoutsAdd(
              projectId: from.projectId,
              found: [
                DiscoveredRepository(
                  name: p.basename(location.path),
                  path: location,
                ),
              ],
              orRoot: false,
            ),
          );
          recorded =
              rows.firstOrNull ??
              RepositoryDao(
                _context.database,
              ).getByLocation(location).firstOrNull;
          made = {...result, 'repositoryId': ?recorded?.id};
        }
        if (recorded == null) {
          throw StateError(
            'The worktree was made at ${result['path']} but could not be '
            'recorded, so it cannot be attached. Run project_rescan, then '
            'attach the checkout it reports.',
          );
        }
        checkout = recorded;
      }
      final links = _context.write(
        SessionLinkAdd(sessionId: session.id, repositoryId: checkout.id),
      );
      return <String, Object?>{
        'sessionId': session.id,
        ..._describe(checkout),
        'isolation': made != null
            ? 'a worktree of this session\'s own: its own tree, index and '
                  'branch ${made['branch']}'
            : 'a shared checkout: any other session working in '
                  '${checkout.name} has the same working tree, index and branch',
        'worktree': ?made,
        'attached': [
          for (final link in orderedLinks(links))
            if (RepositoryDao(_context.database).getById(link.repositoryId)
                case final repository?)
              {..._describe(repository), 'role': link.role},
        ],
      };
    });
  }

  Future<Object?>? _detach(Map<String, dynamic> args, String? callerSessionId) {
    final session = _session(args, callerSessionId);
    final checkout = _checkout(args['repositoryId'] as String?);
    if (checkout.id == session.repositoryId) {
      throw StateError(
        '${checkout.name} is the checkout this session runs in, so it cannot '
        'be detached. Only additional checkouts can.',
      );
    }
    return runTool(() async {
      final links = _context.write(
        SessionLinkRemove(sessionId: session.id, repositoryId: checkout.id),
      );
      return <String, Object?>{
        'sessionId': session.id,
        'detached': checkout.id,
        'attached': [
          for (final link in orderedLinks(links))
            if (RepositoryDao(_context.database).getById(link.repositoryId)
                case final repository?)
              {..._describe(repository), 'role': link.role},
        ],
      };
    });
  }

  Map<String, Object?> _describe(Repository repository) => <String, Object?>{
    'repositoryId': repository.id,
    'name': repository.name,
    'path': repository.path.path,
    'environmentId': repository.path.environmentId,
    'projectId': repository.projectId,
    'project':
        ProjectDao(_context.database).getById(repository.projectId)?.name ??
        'not recorded',
  };

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// The schemas for [SessionCheckoutToolSet].
const List<Map<String, Object?>> sessionCheckoutToolSchemas = [
  {
    'name': 'session_checkout_attach',
    'description':
        'Attach a checkout to a session — yours, unless sessionId names '
        'another — so its files show on the session and you can work in it. '
        'The checkout comes from list_checkouts; one this machine lacks is '
        'cloned first with project_add and a gitUrl. Pass worktree to make a '
        'worktree of the checkout on a new branch (as worktree_create does, '
        'with the same refusals) and attach that instead, so your work is on '
        'a branch of its own. A session in a project may only attach that '
        "project's checkouts; a session without a project (one running in "
        'Scratch) may attach any.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description': 'The checkout to attach, from list_checkouts.',
        },
        'sessionId': {
          'type': 'string',
          'description':
              'The session to attach it to. Defaults to the calling session.',
        },
        'worktree': {
          'type': 'object',
          'description':
              'Make a worktree of the checkout first and attach that. '
              'name is the folder name, branch the new branch, baseRef what '
              'to branch from (defaults to the checkout\'s HEAD).',
          'properties': {
            'name': {'type': 'string'},
            'branch': {'type': 'string'},
            'baseRef': {'type': 'string'},
          },
          'required': ['name', 'branch'],
        },
      },
      'required': ['repositoryId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'repositoryId': {'type': 'string'},
        'name': {'type': 'string'},
        'path': {'type': 'string'},
        'environmentId': {'type': 'string'},
        'projectId': {'type': 'string'},
        'project': {'type': 'string'},
        'isolation': {'type': 'string'},
        'worktree': {'type': 'object'},
        'attached': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['sessionId', 'repositoryId', 'path', 'attached'],
    },
  },
  {
    'name': 'session_checkout_detach',
    'description':
        'Detach an additional checkout from a session (yours unless sessionId '
        'names another). Nothing on disk changes: the worktree or clone stays '
        'where it is. The checkout a session runs in cannot be detached.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description':
              'The checkout to detach, from the session\'s own list.',
        },
        'sessionId': {
          'type': 'string',
          'description': 'Defaults to the calling session.',
        },
      },
      'required': ['repositoryId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'detached': {'type': 'string'},
        'attached': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['sessionId', 'detached', 'attached'],
    },
  },
];
