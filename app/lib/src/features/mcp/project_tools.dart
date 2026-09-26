import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../environments/application/environment_providers.dart';
import '../projects/application/project_service.dart';
import '../projects/application/projects_controller.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_git/repositories.dart';

/// Adding a project to the workspace and editing one that is already there —
/// the two writes `list_projects` could only describe. Both go through
/// `ProjectsController`, so an agent and the New Project dialog cannot take
/// different paths to the same row.
///
/// The server runs both tools itself (and serves their schemas); a call
/// reaches this only for a project on an SSH host, whose folders only this
/// app reaches.
class ProjectControlTools {
  ProjectControlTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{'project_add', 'project_update'};

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'project_add' => _add(args),
        'project_update' => _update(args),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  Future<Object?> _add(Map<String, dynamic> args) async {
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
    if (_container.read(environmentsDataProvider).getById(environmentId) ==
        null) {
      throw ArgumentError(
        'No environment with id $environmentId. list_agents names the ones '
        'this workspace knows.',
      );
    }

    // The name is the folder's own when the caller did not choose one, which is
    // what the dialog fills in for a person.
    final name =
        _text(args['name']) ??
        (path == null ? repoNameFromUrl(gitUrl!) : _leafOf(path));

    final result = await _container
        .read(projectsControllerProvider.notifier)
        .createProject(
          name: name,
          targetEnvironmentId: environmentId,
          folderPath: path ?? '',
          gitRepoUrl: gitUrl,
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
  }

  Future<Object?> _update(Map<String, dynamic> args) async {
    final projectId = _text(args['projectId']);
    if (projectId == null) {
      throw ArgumentError('projectId is required. list_projects has the ids.');
    }
    final clearDefault =
        args['defaultRepositoryId'] == null &&
        args.containsKey('defaultRepositoryId');

    final result = await _container
        .read(projectsControllerProvider.notifier)
        .updateProject(
          projectId,
          name: _text(args['name']),
          folderPath: _text(args['path']),
          targetEnvironmentId: _text(args['environmentId']),
          defaultRepositoryId: _text(args['defaultRepositoryId']),
          clearDefaultRepository: clearDefault,
        );

    return <String, Object?>{
      ..._describe(result.project),
      // Named separately because they call for different responses: a rebased
      // checkout kept its id and every session with it, one left behind did not
      // move and nothing here knows where it went.
      'rebased': [
        for (final repository in result.rebased) _describeCheckout(repository),
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
