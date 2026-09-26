import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';

import 'checkout_reach.dart';
import 'project_folders.dart';
import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// Adding a project to the workspace and editing one that is already there —
/// the two writes `list_projects` could only describe. The folders are
/// looked at here ([ProjectFolders]) and the rows written through the data
/// service, which every client is told of. A project in an environment the
/// server does not reach (an SSH host) is handed to the app.
class ProjectToolSet extends ServerToolSet {
  ProjectToolSet(
    this._context, {
    required CheckoutReach reach,
    required ProjectFolders folders,
  }) : _reach = reach,
       _folders = folders;

  final ServerToolContext _context;
  final CheckoutReach _reach;
  final ProjectFolders _folders;

  @override
  List<Map<String, Object?>> get schemas => projectToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    try {
      return switch (tool) {
        'project_add' => _add(arguments),
        'project_update' => _update(arguments),
        _ => throw ArgumentError('Unknown tool: $tool'),
      };
    } on Object catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<Object?>? _add(Map<String, dynamic> args) {
    final path = _text(args['path']);
    final gitUrl = _text(args['gitUrl']);
    if (path == null && gitUrl == null) {
      throw ArgumentError(
        'Pass path, gitUrl, or both. With a gitUrl and no path a WSL or SSH '
        'environment clones into ~/karmashala/<repo>; a local one needs the '
        'folder spelled out.',
      );
    }

    final environmentId =
        _text(args['environmentId']) ?? localHostEnvironmentId;
    final environment = _reach.environment(environmentId);
    if (environment == null) {
      throw ArgumentError(
        'No environment with id $environmentId. list_agents names the ones '
        'this workspace knows.',
      );
    }
    if (!_reach.reaches(environment)) return null;

    // The name is the folder's own when the caller did not choose one, which
    // is what the dialog fills in for a person.
    final name =
        _text(args['name']) ??
        (path == null ? repoNameFromUrl(gitUrl!) : _leafOf(path));

    return runTool(() async {
      final result = await _folders.create(
        name: name,
        target: environment,
        targetPath: path ?? '',
        gitUrl: gitUrl,
        workspaceId: _text(args['workspaceId']),
      );
      return <String, Object?>{
        ..._describe(result.project),
        'checkouts': [
          for (final repository in result.repositories)
            _describeCheckout(repository),
        ],
        'count': result.repositories.length,
      };
    });
  }

  Future<Object?>? _update(Map<String, dynamic> args) {
    final projectId = _text(args['projectId']);
    if (projectId == null) {
      throw ArgumentError('projectId is required. list_projects has the ids.');
    }
    final clearDefault =
        args['defaultRepositoryId'] == null &&
        args.containsKey('defaultRepositoryId');

    final project = ProjectDao(_context.database).getById(projectId);
    if (project == null) {
      throw StateError('This project is no longer in the workspace.');
    }
    final targetEnvironmentId = _text(args['environmentId']);
    final environmentId = targetEnvironmentId ?? project.root.environmentId;
    final target = _reach.environment(environmentId) ?? _reach.host;
    if (_reach.host == null || target == null) {
      throw StateError('No execution environments available.');
    }
    if (!_reach.reaches(target)) return null;

    final folderPath = _text(args['path']);
    final root = folderPath == null
        ? (targetEnvironmentId == null
              ? null
              : EnvironmentPath(
                  environmentId: environmentId,
                  path: project.root.path,
                ))
        : EnvironmentPath(environmentId: environmentId, path: folderPath);

    return runTool(() async {
      final result = await _folders.update(
        project,
        target: target,
        name: _text(args['name']),
        root: root,
        defaultRepositoryId: _text(args['defaultRepositoryId']),
        clearDefaultRepository: clearDefault,
      );
      return <String, Object?>{
        ..._describe(result.project),
        // Named separately because they call for different responses: a
        // rebased checkout kept its id and every session with it, one left
        // behind did not move and nothing here knows where it went.
        'rebased': [
          for (final repository in result.rebased)
            _describeCheckout(repository),
        ],
        'leftBehind': [
          for (final repository in result.leftBehind)
            _describeCheckout(repository),
        ],
        'discovered': [
          for (final repository in result.discovered)
            _describeCheckout(repository),
        ],
      };
    });
  }

  Map<String, Object?> _describe(Project project) => <String, Object?>{
    'projectId': project.id,
    'name': project.name,
    'environmentId': project.environmentId,
    'path': project.root.path,
    if (project.workspaceId != null) 'workspaceId': project.workspaceId,
    if (project.defaultRepositoryId != null)
      'defaultRepositoryId': project.defaultRepositoryId,
  };

  Map<String, Object?> _describeCheckout(Repository repository) =>
      <String, Object?>{
        'repositoryId': repository.id,
        'name': repository.name,
        'path': repository.path.path,
        'environmentId': repository.path.environmentId,
      };

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _leafOf(String path) {
    final cleaned = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final cut = cleaned.lastIndexOf(RegExp(r'[\\/]'));
    return cut == -1 || cut == cleaned.length - 1
        ? cleaned
        : cleaned.substring(cut + 1);
  }
}

/// The schemas for [ProjectToolSet].
const List<Map<String, Object?>> projectToolSchemas = [
  {
    'name': 'project_add',
    'description':
        'Add a project to the Karmashala workspace: adopt a folder that is '
        'already there, clone a Git repository into one, or both. Every Git '
        'checkout beneath the folder is discovered and recorded, and any CLI '
        'sessions those checkouts already have are imported. Use this rather '
        'than telling the user to open the New Project dialog.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'The project folder, spelled for its own environment — a '
              'Windows path locally, a POSIX path in WSL or over SSH. With a '
              'gitUrl this is where the clone lands; without one the folder '
              'must already exist.',
        },
        'gitUrl': {
          'type': 'string',
          'description':
              'A repository to clone first. With no path, WSL and SSH clone '
              'into ~/karmashala/<repo>; a local environment refuses, because '
              'there is no obvious folder to choose.',
        },
        'name': {
          'type': 'string',
          'description':
              'What to call it. Defaults to the folder\'s own last segment, '
              'or the repository name when only a gitUrl was given.',
        },
        'environmentId': {
          'type': 'string',
          'description':
              'Where the folder lives. Defaults to this machine; '
              'list_agents names the environments this workspace knows.',
        },
        'workspaceId': {
          'type': 'string',
          'description': 'The context to file it under, when there is one.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {'type': 'string'},
        'name': {'type': 'string'},
        'environmentId': {'type': 'string'},
        'path': {'type': 'string'},
        'count': {'type': 'number'},
        'checkouts': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['projectId', 'name', 'path', 'checkouts', 'count'],
    },
  },
  {
    'name': 'project_update',
    'description':
        'Edit a project already in the workspace: rename it, move its root '
        'folder, or set which checkout its one-click "New session" runs in. '
        'A moved root is read before anything is written, so a folder that is '
        'not there changes nothing. Checkouts under the old root are rewritten '
        'in place and **keep their ids**, so the sessions that reference them '
        'still do; any that were not under the old root are reported as '
        'leftBehind rather than guessed at.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {
          'type': 'string',
          'description': 'Which project, from list_projects.',
        },
        'name': {'type': 'string', 'description': 'A new name.'},
        'path': {
          'type': 'string',
          'description':
              'A new root folder, spelled for its environment. Omit to leave '
              'the root alone.',
        },
        'environmentId': {
          'type': 'string',
          'description':
              'The environment the new root lives in, when the project is '
              'moving between environments as well as folders.',
        },
        'defaultRepositoryId': {
          'type': ['string', 'null'],
          'description':
              'The checkout a session started at the project runs in — '
              'list_checkouts has the ids. Explicit null puts it back to the '
              'first checkout the picker offers.',
        },
      },
      'required': ['projectId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {'type': 'string'},
        'name': {'type': 'string'},
        'environmentId': {'type': 'string'},
        'path': {'type': 'string'},
        'rebased': {
          'type': 'array',
          'items': {'type': 'object'},
        },
        'leftBehind': {
          'type': 'array',
          'items': {'type': 'object'},
        },
        'discovered': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['projectId', 'name', 'path'],
    },
  },
];
