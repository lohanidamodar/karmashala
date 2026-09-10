import 'package:riverpod/riverpod.dart';

import '../explorer/application/checkout.dart';
import '../explorer/application/checkout_picker.dart';
import '../git/application/changes_providers.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../sessions/application/delivery_providers.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/domain/session_checkouts.dart';

/// Where the work is: the checkouts under a project, and what one of them owes.
/// Every session runs in a checkout, where `list_projects` stops at the project.
class WorkspaceControlTools {
  WorkspaceControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;
  final String? callerSessionId;

  static const Set<String> _names = <String>{
    'list_checkouts',
    'project_rescan',
    'select_checkout',
    'delivery_status',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'list_checkouts' => _listCheckouts(args['projectId'] as String?),
        'project_rescan' => _rescan(args['projectId'] as String?),
        'select_checkout' => _select(args['repositoryId'] as String?),
        'delivery_status' => _delivery(_targetSession(args)),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  String _targetSession(Map<String, dynamic> args) {
    final named = args['sessionId'] as String?;
    if (named != null && named.trim().isNotEmpty) return named.trim();
    final caller = callerSessionId;
    if (caller != null && caller.isNotEmpty) return caller;
    throw ArgumentError(
      'No sessionId, and this caller is not running inside a session. Pass '
      'sessionId — list_sessions has the ids.',
    );
  }

  Future<Object?> _listCheckouts(String? projectId) async {
    if (projectId == null || projectId.isEmpty) {
      throw ArgumentError('projectId is required. list_projects has the ids.');
    }
    final repositories = _container
        .read(repositoryDaoProvider)
        .getByProject(projectId);
    if (repositories.isEmpty) {
      throw StateError(
        'No project with id $projectId, or it has no checkouts. Try '
        'project_rescan.',
      );
    }
    // One `git worktree list` per family, and it may simply fail: a checkout
    // whose git could not answer is absent from the map rather than wrong in it.
    final labels = await _container.read(
      checkoutLabelsProvider(projectId).future,
    );
    final selected = _container.read(selectedRepositoryIdProvider);
    // Who else is standing here: without occupancy, fan-out candidates sharing
    // every repository but the primary one could not notice each other.
    final rows = _container.read(sessionDaoProvider).getAll();
    return <String, Object?>{
      'projectId': projectId,
      'checkouts': <Object?>[
        for (final repository in repositories)
          <String, Object?>{
            'repositoryId': repository.id,
            'name': repository.name,
            'path': repository.path.path,
            'environmentId': repository.path.environmentId,
            'selected': repository.id == selected,
            'branch': labels[repository.id]?.branch ?? 'not recorded',
            'isWorktree': labels[repository.id]?.isWorktree,
            // Sessions the workspace records as working in this exact
            // directory: an empty list is **not** a promise that nobody is here.
            'sessionsWorkingHere': <Object?>[
              for (final session in sessionsWorkingIn(
                repository.path,
                excluding: '',
                among: rows,
                pathsMatch: samePath,
              ))
                <String, Object?>{
                  'sessionId': session.id,
                  'title': session.title,
                  'status': session.status.name,
                },
            ],
          },
      ],
    };
  }

  /// Re-reads a project's directory for checkouts it does not know about, and
  /// returns what is there afterwards: a diff would be a fact nobody measured.
  Future<Object?> _rescan(String? projectId) async {
    if (projectId == null || projectId.isEmpty) {
      throw ArgumentError('projectId is required. list_projects has the ids.');
    }
    final found = await _container
        .read(projectsControllerProvider.notifier)
        .rediscover(projectId);
    return <String, Object?>{
      'projectId': projectId,
      'checkouts': <Object?>[
        for (final repository in found)
          <String, Object?>{
            'repositoryId': repository.id,
            'name': repository.name,
            'path': repository.path.path,
          },
      ],
      'count': found.length,
    };
  }

  /// Points Explorer, the diff view and the side panel at one checkout, through
  /// the same `CheckoutPicker` the side panel's own picker calls.
  Object? _select(String? repositoryId) {
    if (repositoryId == null || repositoryId.isEmpty) {
      throw ArgumentError(
        'repositoryId is required. list_checkouts has the ids.',
      );
    }
    final Repository? repository = _container
        .read(repositoryDaoProvider)
        .getById(repositoryId);
    if (repository == null) {
      throw StateError('No checkout with id $repositoryId.');
    }
    _container.read(checkoutPickerProvider).select(repository);
    return <String, Object?>{
      'repositoryId': repository.id,
      'name': repository.name,
      'path': repository.path.path,
      'projectId': repository.projectId,
      'selected': true,
    };
  }

  /// What a session's checkout still owes. Every count is nullable at the
  /// source, and an unknown reads "not recorded" rather than `0`.
  Future<Object?> _delivery(String sessionId) async {
    final session = _container.read(sessionDaoProvider).getById(sessionId);
    if (session == null) {
      throw StateError('No session with id $sessionId.');
    }
    final delivery = await _container.read(
      sessionDeliveryProvider(sessionId).future,
    );
    final actions = _container.read(
      sessionDeliveryActionsProvider(sessionId),
    );
    final pr = delivery.pullRequest;
    return <String, Object?>{
      'sessionId': sessionId,
      'title': session.title,
      'stage': delivery.stage.label,
      'branch': delivery.branch ?? 'not recorded',
      'baseBranch': delivery.baseBranch ?? 'not recorded',
      'upstream': delivery.upstream ?? 'not recorded',
      'hasWorktree': delivery.hasWorktree,
      'archived': delivery.archived,
      'dirtyFiles': delivery.dirtyFiles ?? 'not recorded',
      'aheadOfBase': delivery.aheadOfBase ?? 'not recorded',
      'behindBase': delivery.behindBase ?? 'not recorded',
      'unpushed': delivery.unpushed ?? 'not recorded',
      'agentRunning': delivery.agentRunning ?? 'not recorded',
      'pullRequest': pr == null
          ? 'not recorded — no open pull request was found for this branch'
          : <String, Object?>{
              'number': pr.number,
              'title': pr.title,
              'state': pr.state.name,
              'url': pr.url,
              'isDraft': pr.isDraft,
              'mergeable': pr.mergeable ?? 'not recorded',
              'reviewDecision': pr.reviewDecision?.name ?? 'not recorded',
              'checks': pr.checks.toString(),
            },
      // What the delivery strip would offer a user looking at this session, so
      // an agent and the person beside it are choosing from the same list.
      'actions': <Object?>[
        for (final offered in actions)
          <String, Object?>{
            'action': offered.action.name,
            'label': offered.action.label,
            'primary': offered.isPrimary,
            'available': offered.disabledReason == null,
            'unavailableBecause': offered.disabledReason,
          },
      ],
    };
  }
}

/// The schemas for [WorkspaceControlTools].
const List<Map<String, dynamic>> workspaceControlToolSchemas = [
  {
    'name': 'list_checkouts',
    'description':
        'The checkouts under a project: the main clone and every worktree, '
        'with the branch each is on, which one the side panel is pointed at, '
        'and which sessions Karmashala records as working in each. A branch '
        'reads "not recorded" when git could not be asked — that is not the '
        'same as being on no branch. Only a session\'s own worktree is '
        'isolated: a session works in one worktree at most, so any other '
        'repository it touches is a checkout shared with every other session '
        'that touches it — same working tree, same index, same branch. Read '
        'sessionsWorkingHere before editing or running a build in a checkout '
        'that is not your own; an empty list means none was recorded, not that '
        'the checkout is free.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {
          'type': 'string',
          'description': 'Which project, from list_projects.',
        },
      },
      'required': ['projectId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {'type': 'string'},
        'checkouts': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'repositoryId': {'type': 'string'},
              'name': {'type': 'string'},
              'path': {'type': 'string'},
              'environmentId': {'type': 'string'},
              'selected': {'type': 'boolean'},
              'branch': {'type': 'string'},
              'isWorktree': {'type': ['boolean', 'null']},
              'sessionsWorkingHere': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'sessionId': {'type': 'string'},
                    'title': {'type': 'string'},
                    'status': {'type': 'string'},
                  },
                  'required': ['sessionId', 'title', 'status'],
                },
              },
            },
            'required': [
              'repositoryId',
              'name',
              'path',
              'branch',
              'sessionsWorkingHere',
            ],
          },
        },
      },
      'required': ['projectId', 'checkouts'],
    },
  },
  {
    'name': 'project_rescan',
    'description':
        'Re-read a project\'s directory for checkouts Karmashala does not '
        'know about yet — a worktree added from the command line, a clone '
        'dropped in beside the others. Returns every checkout found '
        'afterwards, not a list of what changed.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {
          'type': 'string',
          'description': 'Which project, from list_projects.',
        },
      },
      'required': ['projectId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {'type': 'string'},
        'count': {'type': 'number'},
        'checkouts': {'type': 'array', 'items': {'type': 'object'}},
      },
      'required': ['projectId', 'checkouts', 'count'],
    },
  },
  {
    'name': 'select_checkout',
    'description':
        'Point Karmashala\'s Explorer, diff view and side panel at a '
        'checkout. This is what the user sees change on screen, so use it to '
        'show someone where you are working rather than to navigate for '
        'yourself.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description': 'Which checkout, from list_checkouts.',
        },
      },
      'required': ['repositoryId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {'type': 'string'},
        'name': {'type': 'string'},
        'path': {'type': 'string'},
        'projectId': {'type': 'string'},
        'selected': {'type': 'boolean'},
      },
      'required': ['repositoryId', 'selected'],
    },
  },
  {
    'name': 'delivery_status',
    'description':
        'What a session\'s checkout still owes: branch, how far ahead of and '
        'behind its base, dirty files, unpushed commits, its pull request, and '
        'the actions Karmashala offers on it. Omit sessionId for your own '
        'session. Any value Karmashala could not measure reads "not recorded" '
        '— never 0, and never "none". A failed git call and a clean tree are '
        'different facts.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session. Defaults to the calling session.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'stage': {'type': 'string'},
        'branch': {'type': 'string'},
        'baseBranch': {'type': 'string'},
        'upstream': {'type': 'string'},
        'hasWorktree': {'type': 'boolean'},
        'archived': {'type': 'boolean'},
        'dirtyFiles': {'type': ['number', 'string']},
        'aheadOfBase': {'type': ['number', 'string']},
        'behindBase': {'type': ['number', 'string']},
        'unpushed': {'type': ['number', 'string']},
        'agentRunning': {'type': ['boolean', 'string']},
        'pullRequest': {'type': ['object', 'string']},
        'actions': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'action': {'type': 'string'},
              'label': {'type': 'string'},
              'primary': {'type': 'boolean'},
              'available': {'type': 'boolean'},
              'unavailableBecause': {'type': ['string', 'null']},
            },
            'required': ['action', 'label', 'available'],
          },
        },
      },
      'required': ['sessionId', 'stage', 'branch', 'actions'],
    },
  },
];
