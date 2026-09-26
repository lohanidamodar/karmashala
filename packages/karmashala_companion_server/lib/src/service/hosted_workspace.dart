import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:path/path.dart' as p;

import '../domain/agent_options.dart';
import '../store/workspace_rows.dart';

/// The projects a phone sees, and the one it may add, while the session host
/// answers with no desktop app connected — a machine with no desktop at all,
/// or one whose app is closed.
///
/// **Only what this host can start in.** The host launches agents in its own
/// environment alone, so a checkout on WSL or over SSH is left out of
/// `workspace.list` rather than offered with nothing to start it; the flat
/// `projects.list` still names every project, since it is a place, not a start.
class HostedWorkspace {
  HostedWorkspace({
    required this.rows,
    required this.isHere,
    required this.now,
    required this.newId,
    this.registry = AgentRegistry.builtIn,
    this.discovery = const LocalRepositoryDiscoveryService(),
  });

  final WorkspaceRows rows;

  /// Whether an environment is this machine's own — where this host can
  /// start a process directly.
  final bool Function(ExecutionEnvironment environment) isHere;
  final DateTime Function() now;
  final String Function() newId;
  final AgentRegistry registry;
  final RepositoryDiscoveryService discovery;

  /// Adds in flight, by folder: two phones — or one retrying — asking for the
  /// same folder share one project.
  final _adding = <String, Future<RemoteWorkspaceProject>>{};

  /// Every project with a checkout this host can start in, with the agents
  /// installed here — in the store's order.
  List<RemoteWorkspaceProject> listWorkspace() {
    final environments = {for (final e in rows.environments()) e.id: e};
    final agents = <String, List<RemoteAgentOption>>{};
    List<RemoteAgentOption> agentsIn(String environmentId) =>
        agents[environmentId] ??= [
          for (final installation in rows.installationsIn(environmentId))
            _agentOption(installation),
        ];
    return [
      for (final project in rows.projects())
        ?_project(project, environments, agentsIn),
    ];
  }

  /// Every project the store holds, flat.
  List<RemoteWorkspaceProject> listProjects() {
    final environments = {for (final e in rows.environments()) e.id: e};
    return [
      for (final project in rows.projects())
        _described(project, environments[project.root.environmentId]),
    ];
  }

  /// Adds the folder [path] on this machine as a project called [name], with
  /// the git repositories found under it as its checkouts — or the folder
  /// itself when there are none, as the desktop does. The same folder asked
  /// for again answers the project it already is.
  Future<RemoteWorkspaceProject> addProject(String name, String path) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || trimmedName.contains(_control)) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'a project needs a name and the absolute path of an existing folder '
        'on this machine',
      );
    }
    final folder = await _existingFolder(path);
    final pending = _adding[folder];
    if (pending != null) return pending;
    final adding = _add(trimmedName, folder);
    _adding[folder] = adding;
    try {
      return await adding;
    } finally {
      if (identical(_adding[folder], adding)) unawaited(_adding.remove(folder));
    }
  }

  Future<RemoteWorkspaceProject> _add(String name, String folder) async {
    final here = _hereEnvironment();
    for (final project in rows.projects()) {
      if (project.root.environmentId == here.id &&
          p.equals(project.root.path, folder)) {
        return _project(project, {here.id: here}, (id) {
              return [
                for (final installation in rows.installationsIn(id))
                  _agentOption(installation),
              ];
            }) ??
            _described(project, here);
      }
    }
    final root = EnvironmentPath(environmentId: here.id, path: folder);
    final List<DiscoveredRepository> found;
    try {
      found = await discovery.discover(root);
    } on RepositoryDiscoveryException catch (error) {
      throw RemoteApiRefusal(ErrorCode.badRequest, error.message);
    }
    final at = now().toUtc();
    final project = (id: newId(), name: name, root: root, createdAt: at);
    final repositories = [
      for (final repository in found)
        Repository(
          id: newId(),
          projectId: project.id,
          name: repository.name,
          path: repository.path,
          createdAt: at,
        ),
    ];
    // Git is not what makes a directory runnable: every agent starts in a
    // plain one, so a folder with no repository is its own checkout.
    if (repositories.isEmpty) {
      repositories.add(
        Repository(
          id: newId(),
          projectId: project.id,
          name: name,
          path: root,
          createdAt: at,
        ),
      );
    }
    rows.insertProject(project, repositories);
    final agents = [
      for (final installation in rows.installationsIn(here.id))
        _agentOption(installation),
    ];
    return _described(
      project,
      here,
      checkouts: [
        for (final repository in repositories)
          _checkout(project, repository, here, agents),
      ],
    );
  }

  /// This machine's own environment row, or a refusal naming what is missing.
  ExecutionEnvironment _hereEnvironment() {
    for (final environment in rows.environments()) {
      if (isHere(environment)) return environment;
    }
    throw const RemoteApiRefusal(
      ErrorCode.notFound,
      'this machine has recorded no environment of its own yet, so a project '
      'cannot be placed on it — find its agents first',
    );
  }

  /// [path] as the existing folder it names, links resolved, or the refusal.
  static Future<String> _existingFolder(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty ||
        trimmed.contains(_control) ||
        !p.isAbsolute(trimmed) ||
        trimmed.startsWith(r'\\') ||
        trimmed.startsWith('//')) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'a project needs the absolute path of an existing folder on this '
        'machine',
      );
    }
    final type = await FileSystemEntity.type(trimmed);
    if (type == FileSystemEntityType.notFound) {
      throw const RemoteApiRefusal(
        ErrorCode.notFound,
        'there is no folder at that path on this machine',
      );
    }
    final directory = Directory(trimmed);
    if (!await directory.exists()) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'that path is a file, not a folder',
      );
    }
    final resolved = p.normalize(await directory.resolveSymbolicLinks());
    // A local-looking link can resolve onto a network share.
    if (resolved.startsWith(r'\\') || resolved.startsWith('//')) {
      throw const RemoteApiRefusal(
        ErrorCode.badRequest,
        'the folder must be on this machine, not a network share',
      );
    }
    return resolved;
  }

  RemoteWorkspaceProject? _project(
    ProjectRow project,
    Map<String, ExecutionEnvironment> environments,
    List<RemoteAgentOption> Function(String environmentId) agentsIn,
  ) {
    final checkouts = [
      for (final repository in rows.repositoriesOf(project.id))
        if (environments[repository.path.environmentId] case final env?
            when isHere(env))
          _checkout(project, repository, env, agentsIn(env.id)),
    ]..sort((a, b) => (a.path ?? '').compareTo(b.path ?? ''));
    if (checkouts.isEmpty) return null;
    return _described(
      project,
      environments[project.root.environmentId],
      checkouts: checkouts,
    );
  }

  RemoteCheckoutOption _checkout(
    ProjectRow project,
    Repository repository,
    ExecutionEnvironment environment,
    List<RemoteAgentOption> agents,
  ) {
    final sub = p.isWithin(project.root.path, repository.path.path)
        ? p.relative(repository.path.path, from: project.root.path)
        : null;
    return RemoteCheckoutOption(
      repositoryId: repository.id,
      name: repository.name,
      path: repository.path.path,
      subPath: sub,
      environmentName: environmentLabel(environment),
      folderMissing: !Directory(repository.path.path).existsSync(),
      agents: agents,
    );
  }

  RemoteWorkspaceProject _described(
    ProjectRow project,
    ExecutionEnvironment? environment, {
    List<RemoteCheckoutOption> checkouts = const [],
  }) => RemoteWorkspaceProject(
    projectId: project.id,
    name: project.name,
    path: project.root.path,
    environmentName: environment == null ? null : environmentLabel(environment),
    environmentBadge: environment == null
        ? null
        : environmentBadge(environment),
    environmentId: project.root.environmentId,
    environmentKind: environment?.kind.name,
    checkouts: checkouts,
  );

  RemoteAgentOption _agentOption(AgentInstallation installation) {
    final descriptor = registry.byId(installation.agentId);
    return remoteAgentOptionFor(
      installation,
      descriptor,
      // No settings here: a new session starts under the agent's own default.
      defaultMode:
          descriptor?.launch.permission.resolveStored(null).canonical ?? '',
    );
  }

  static final _control = RegExp(r'[\x00-\x1f\x7f]');
}
