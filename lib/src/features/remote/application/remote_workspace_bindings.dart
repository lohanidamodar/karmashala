/// The projects a phone can see, and the one write that adds another.
///
/// `workspace.list`, `projects.list` and `project.add` are one family because
/// they all read or write the project table and nothing else. Like
/// `sessions.list`, the reads report only what the desktop already holds: the
/// branch comes from the cached checkout stat and no git is started.
library;

import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../explorer/application/checkout.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/host.dart';
import 'remote_binding_support.dart';
import 'remote_session_start_bindings.dart';

/// What could be started here, in the Explorer's own order: projects as the
/// tree sorts them, checkouts by path, and under each checkout the agents
/// installed in the environment it lives in.
///
/// A project with no checkout is omitted — there is nowhere in it to start
/// anything, and listing it would offer a choice that does not exist. Like
/// `sessions.list`, this reads only what the desktop already holds: the
/// branch comes from the cached checkout stat and no git is started.
List<RemoteWorkspaceProject> listRemoteWorkspace(Ref ref) {
  final installations = ref.read(agentInstallationDaoProvider);
  final byEnvironment = <String, List<RemoteAgentOption>>{};
  List<RemoteAgentOption> agentsIn(String environmentId) =>
      byEnvironment[environmentId] ??= [
        for (final installation in installations.getByEnvironment(
          environmentId,
        ))
          remoteAgentOption(ref, installation),
      ];

  // Read once and looked up per row: a workspace is mostly two or three
  // environments spread over many checkouts, and this runs on every
  // `workspace.list`.
  final environments = {
    for (final environment
        in ref.read(executionEnvironmentDaoProvider).getAll())
      environment.id: environment,
  };
  // The desktop's own name for where a folder lives. Null for an
  // environment row the desktop no longer holds — the phone then falls back
  // to the path rather than inventing a name for it.
  String? nameOf(String environmentId) {
    final environment = environments[environmentId];
    return environment == null ? null : environmentLabel(environment);
  }
  String? badgeOf(String environmentId) {
    final environment = environments[environmentId];
    return environment == null ? null : environmentBadge(environment);
  }

  final out = <RemoteWorkspaceProject>[];
  for (final project in ref.read(sortedProjectsProvider)) {
    final repositories =
        [...ref.read(repositoryDaoProvider).getByProject(project.id)]..sort(
          (a, b) => canonicalPathKey(
            a.path.path,
          ).compareTo(canonicalPathKey(b.path.path)),
        );
    if (repositories.isEmpty) continue;
    out.add(
      RemoteWorkspaceProject(
        projectId: project.id,
        name: project.name,
        path: project.root.path,
        environmentName: nameOf(project.environmentId),
        environmentBadge: badgeOf(project.environmentId),
        checkouts: [
          for (final repository in repositories)
            RemoteCheckoutOption(
              repositoryId: repository.id,
              name: repository.name,
              path: repository.path.path,
              subPath: relativeSubPath(project.root, repository.path),
              branch: ref.read(remoteCheckoutBranchProvider)(repository.path),
              environmentName: nameOf(repository.environmentId),
              folderMissing: ref.read(remoteFolderMissingProvider)(
                repository.path,
              ),
              agents: agentsIn(repository.environmentId),
            ),
        ],
      ),
    );
  }
  return out;
}

/// Every project the desktop holds, flat — no checkouts, because this is the
/// list a phone picks a *place* from rather than something to start.
List<RemoteWorkspaceProject> listRemoteProjects(Ref ref) => [
  for (final project in ref.read(projectDaoProvider).getAll())
    RemoteWorkspaceProject(
      projectId: project.id,
      name: project.name,
      path: project.root.path,
      environmentName: environmentNameFor(ref, project.environmentId),
      environmentBadge: environmentBadgeFor(ref, project.environmentId),
    ),
];

Future<RemoteWorkspaceProject> addRemoteProject(
  Ref ref,
  String name,
  String path,
) async {
  final trimmedName = name.trim();
  final trimmedPath = path.trim();
  if (trimmedName.isEmpty || trimmedPath.isEmpty ||
      trimmedPath.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      !p.isAbsolute(trimmedPath)) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'name and an existing absolute local desktop path are required',
    );
  }
  if (trimmedPath.startsWith(r'\\') || trimmedPath.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  final canonical = canonicalPathKey(trimmedPath);
  final envDao = ref.read(executionEnvironmentDaoProvider);
  for (final project in ref.read(projectDaoProvider).getAll()) {
    if (project.root.environmentId == localHostEnvironmentId &&
        canonicalPathKey(project.root.path) == canonical) {
      final env = envDao.getById(project.environmentId);
      return RemoteWorkspaceProject(
        projectId: project.id,
        name: project.name,
        path: project.root.path,
        environmentName: env == null ? null : environmentLabel(env),
        environmentBadge: env == null ? null : environmentBadge(env),
      );
    }
  }
  final result = await ref.read(projectsControllerProvider.notifier).createByDiscovery(
    name: trimmedName,
    path: trimmedPath,
  );
  final createdEnv = envDao.getById(result.project.environmentId);
  return RemoteWorkspaceProject(
    projectId: result.project.id,
    name: result.project.name,
    path: result.project.root.path,
    environmentName: createdEnv == null ? null : environmentLabel(createdEnv),
    environmentBadge: createdEnv == null ? null : environmentBadge(createdEnv),
    checkouts: [
      for (final repository in result.repositories)
        RemoteCheckoutOption(
          repositoryId: repository.id,
          name: repository.name,
          path: repository.path.path,
        ),
    ],
  );
}

Future<String> canonicalRemoteProjectPath(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty ||
      trimmed.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      !p.isAbsolute(trimmed)) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'name and an existing absolute local desktop path are required',
    );
  }
  if (trimmed.startsWith(r'\\') || trimmed.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  final directory = Directory(trimmed);
  if (!await directory.exists()) {
    throw const RemoteApiRefusal(ErrorCode.notFound, 'that desktop folder does not exist');
  }
  final canonical = (await directory.resolveSymbolicLinks()).trim();
  // A local-looking junction can resolve onto a UNC/network target. Refuse
  // after resolution as well as before it, so the service never imports a
  // path outside the desktop's local filesystem contract.
  if (canonical.startsWith(r'\\') || canonical.startsWith('//')) {
    throw const RemoteApiRefusal(
      ErrorCode.badRequest,
      'the path must be on the desktop, not a network or WSL path',
    );
  }
  return canonical;
}
