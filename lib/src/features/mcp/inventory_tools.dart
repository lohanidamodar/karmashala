import 'package:riverpod/riverpod.dart';

import '../agents/application/agent_providers.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';
import '../sessions/application/session_providers.dart';
import 'agent_lookup.dart';

/// What exists: the projects, the sessions in them, and the agents installed to
/// run one. None needs the caller's identity — they describe the machine.
class InventoryTools {
  InventoryTools(this._container);

  final ProviderContainer _container;

  static const Set<String> _names = <String>{
    'list_projects',
    'list_sessions',
    'list_agents',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'list_projects' => _listProjects(),
        'list_sessions' => _listSessions(
          query: args['query'] as String?,
          cli: args['cli'] as String?,
        ),
        'list_agents' => _listAgents(),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  List<Map<String, dynamic>> _listProjects() {
    final projects = _container.read(projectsControllerProvider);
    return [
      for (final project in projects)
        {
          'id': project.id,
          'name': project.name,
          'environmentId': project.environmentId,
          'path': project.root.path,
        },
    ];
  }

  List<Map<String, dynamic>> _listSessions({String? query, String? cli}) {
    final projects = _container.read(projectsControllerProvider);
    final repositoryDao = _container.read(repositoryDaoProvider);
    final importedDao = _container.read(importedSessionDaoProvider);
    final needle = query?.trim().toLowerCase();
    final wantCli = parseCli(_container, cli);

    final sessionDao = _container.read(sessionDaoProvider);
    final registry = _container.read(agentRegistryProvider);
    final installDao = _container.read(agentInstallationDaoProvider);

    final sessions = <Map<String, dynamic>>[];
    for (final project in projects) {
      for (final repo in repositoryDao.getByProject(project.id)) {
        // Sessions started **in the app**, invisible here for as long as every
        // session tool read only `imported_sessions`.
        for (final session in sessionDao.getByRepository(repo.id)) {
          final agentId =
              installDao.getById(session.agentInstallationId)?.agentId ?? '';
          if (wantCli != null && agentId != wantCli) continue;
          final haystack = [
            project.name,
            repo.name,
            session.title,
          ].join(' ').toLowerCase();
          if (needle != null &&
              needle.isNotEmpty &&
              !haystack.contains(needle)) {
            continue;
          }
          sessions.add({
            'id': session.id,
            'kind': 'native',
            if (session.externalSessionId != null)
              'externalId': session.externalSessionId,
            'title': session.title,
            'cli': agentId,
            'agent': registry.displayNameFor(agentId),
            'project': project.name,
            'repository': repo.name,
            'environmentId': repo.path.environmentId,
            'status': session.status.name,
            'surface': session.surface.name,
            'view': session.view.name,
            if (session.parentSessionId != null)
              'parentSessionId': session.parentSessionId,
            'createdAt': session.createdAt.toIso8601String(),
          });
        }
        for (final session in importedDao.getByRepository(repo.id)) {
          if (wantCli != null && session.cli != wantCli) continue;
          final haystack = [
            project.name,
            repo.name,
            session.title ?? '',
            session.preview,
          ].join(' ').toLowerCase();
          if (needle != null &&
              needle.isNotEmpty &&
              !haystack.contains(needle)) {
            continue;
          }
          sessions.add({
            'id': session.id,
            'kind': 'imported',
            'externalId': session.externalId,
            'title': session.displayTitle,
            'cli': session.cli,
            'project': project.name,
            'repository': repo.name,
            'environmentId': session.environmentId,
            if (session.updatedAt != null)
              'updatedAt': session.updatedAt!.toIso8601String(),
          });
        }
      }
    }
    return sessions;
  }

  List<Map<String, dynamic>> _listAgents() {
    return [
      for (final install
          in _container.read(agentInstallationDaoProvider).getAll())
        {
          'agentInstallationId': install.id,
          'cli': install.agentId,
          'environmentId': install.environmentId,
          if (install.version != null) 'version': install.version,
          'path': install.executable.path,
        },
    ];
  }
}

/// The schemas for [InventoryTools].
const List<Map<String, dynamic>> inventoryToolSchemas = [
  {
    'name': 'list_projects',
    'description':
        'List the projects known to Karmashala (name, environment, path).',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
  {
    'name': 'list_sessions',
    'description':
        'List coding-agent sessions — both the ones running in Karmashala '
        '("kind": "native", with a status and, when an agent started it, a '
        'parentSessionId) and ones imported from a CLI store ("kind": '
        '"imported"). Optionally filter by a case-insensitive substring '
        '(matched against project, repository, title, and preview) and by CLI '
        '("claude" or "codex").',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'Substring filter, e.g. "appwrite".',
        },
        'cli': {
          'type': 'string',
          'description': 'Filter by agent CLI: "claude" or "codex".',
        },
      },
    },
  },
  {
    'name': 'list_agents',
    'description':
        'List the installed agents available to start sessions with — each '
        'is an (agentInstallationId, cli, environmentId) the caller can pass '
        'to open_new_session. Use this to map a user request like "a codex '
        'session" to a concrete installation.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
  },
];
