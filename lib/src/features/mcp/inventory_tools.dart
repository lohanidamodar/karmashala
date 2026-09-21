import 'package:agent_cli/read.dart'
    show conversationQueryTokens, kConversationQueryMinimum;
import 'package:riverpod/riverpod.dart';

import '../automations/application/scheduled_resume_providers.dart';
import '../agents/application/agent_providers.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../cli_detection/application/session_search.dart';
import '../cli_detection/data/conversation_index_dao.dart';
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
    'session_search',
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
        'session_search' => _searchSessions(args),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// Full-text search over what was said in every conversation, through the
  /// same service quick open uses. Catches the running sessions up first.
  Future<Map<String, dynamic>> _searchSessions(
    Map<String, dynamic> args,
  ) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (conversationQueryTokens(query) == null) {
      throw ArgumentError(
        'query is required: at least $kConversationQueryMinimum characters '
        'with a letter or digit in them.',
      );
    }
    final cliArg = args['cli'] as String?;
    final cli = parseCli(_container, cliArg);
    if (cliArg != null && cliArg.trim().isNotEmpty && cli == null) {
      throw ArgumentError('Unknown cli "$cliArg". list_agents has the ids.');
    }
    final sessionDao = _container.read(sessionDaoProvider);
    final importedDao = _container.read(importedSessionDaoProvider);
    String? conversationId;
    final sessionId = (args['sessionId'] as String?)?.trim();
    if (sessionId != null && sessionId.isNotEmpty) {
      conversationId =
          sessionDao.getById(sessionId)?.externalSessionId ??
          importedDao.getById(sessionId)?.externalId;
      if (conversationId == null) {
        throw ArgumentError(
          'No session with id $sessionId, or it has no conversation recorded '
          'yet. list_sessions has the ids.',
        );
      }
    }
    final limit = ((args['limit'] as num?)?.round() ?? 10).clamp(1, 50);
    final search = _container.read(sessionSearchServiceProvider);
    await search.catchUp();
    final SessionSearchPage page;
    try {
      page = search.search(
        query,
        limit: limit,
        cursor: args['cursor'] as String?,
        filter: SessionSearchFilter(
          conversationId: conversationId,
          cli: cli,
          projectId: args['projectId'] as String?,
          repositoryId: args['repositoryId'] as String?,
          after: _instant(args['after'], 'after'),
          before: _instant(args['before'], 'before'),
        ),
      );
    } on StaleSearchCursor catch (stale) {
      throw StateError(stale.toString());
    }
    final registry = _container.read(agentRegistryProvider);
    final results = <Map<String, dynamic>>[];
    for (final hit in page.hits) {
      final native = sessionDao.getByExternalSessionId(hit.sessionId);
      final imported = native == null
          ? importedDao.getByExternal(hit.cli, hit.sessionId)
          : null;
      if (native == null && imported == null) continue;
      results.add({
        'sessionId': native?.id ?? imported!.id,
        'kind': native != null ? 'native' : 'imported',
        'conversationId': hit.sessionId,
        'title': native?.title ?? imported!.displayTitle,
        'cli': hit.cli,
        'agent': registry.displayNameFor(hit.cli),
        'excerpt': hit.excerpt,
        'role': hit.role,
        'turn': hit.ordinal,
        if (hit.at != null) 'at': hit.at!.toIso8601String(),
        'matches': hit.matches,
        if (hit.tier != null) 'match': hit.tier!.name,
        if (hit.indexedAt != null)
          'indexedAt': hit.indexedAt!.toIso8601String(),
      });
    }
    return {
      'query': query,
      'results': results,
      'nextCursor': page.nextCursor,
      'note': results.isEmpty
          ? 'Nothing indexed matches. Only what users and agents said is '
                'indexed — not tool calls, tool output or thinking — and a '
                'session is searchable once its transcript has been read.'
          : 'Best first. "match" says how strictly: phrase, allWords, '
                'repaired (a word was corrected to one the index holds), or '
                'anyWord.',
    };
  }

  static DateTime? _instant(Object? value, String name) {
    if (value == null) return null;
    final parsed = value is String ? DateTime.tryParse(value.trim()) : null;
    if (parsed == null) {
      throw ArgumentError('$name must be an ISO-8601 date or instant.');
    }
    return parsed.toUtc();
  }

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

    // Read-only: an agent can see a resume is waiting, never arm one.
    final resumes = {
      for (final resume in _container.read(scheduledResumeDaoProvider).live())
        resume.sessionId: resume,
    };

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
            if (resumes[session.id] case final resume?)
              'scheduledResume': {
                'state': resume.state.name,
                'fireAt': resume.fireAt.toIso8601String(),
                if (resume.windowLabel != null) 'window': resume.windowLabel,
              },
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
  {
    'name': 'session_search',
    'description':
        'Search what was said in every agent conversation on this machine — '
        'user prompts and agent replies, not tool calls, tool output or '
        'thinking. Returns one result per session, best match first, with an '
        'excerpt around the match. Words are matched as a phrase first, then '
        'all of them; only when that finds nothing, with a misspelt word '
        'corrected, and only when that finds nothing, any one of them. Each '
        'result says which. Query text is words, never operators: '
        'narrow with the filter arguments instead. Pass nextCursor back as '
        'cursor for the next page; a cursor is refused once the index has '
        'changed, and the search must then be asked again.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'What was said, e.g. "stripe webhook signature".',
        },
        'sessionId': {
          'type': 'string',
          'description': 'Search only this session\'s conversation.',
        },
        'cli': {
          'type': 'string',
          'description': 'Only this agent: "claude", "codex", ….',
        },
        'projectId': {
          'type': 'string',
          'description': 'Only sessions in this project (list_projects).',
        },
        'repositoryId': {
          'type': 'string',
          'description': 'Only sessions in this repository.',
        },
        'after': {
          'type': 'string',
          'description':
              'ISO-8601. Only turns said at or after this. A turn whose time '
              'was never recorded is excluded by any date bound.',
        },
        'before': {
          'type': 'string',
          'description': 'ISO-8601. Only turns said before this.',
        },
        'limit': {
          'type': 'number',
          'description': 'Sessions per page (default 10, at most 50).',
        },
        'cursor': {
          'type': 'string',
          'description': 'nextCursor from the previous page of this search.',
        },
      },
      'required': ['query'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'results': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'sessionId': {'type': 'string'},
              'kind': {
                'type': 'string',
                'enum': ['native', 'imported'],
              },
              'conversationId': {'type': 'string'},
              'title': {'type': 'string'},
              'cli': {'type': 'string'},
              'agent': {'type': 'string'},
              'excerpt': {'type': 'string'},
              'role': {
                'type': 'string',
                'enum': ['user', 'agent'],
              },
              'turn': {
                'type': 'number',
                'description':
                    'Position in the transcript as parsed. A hint: a format '
                    'change in the CLI shifts it.',
              },
              'at': {'type': 'string'},
              'matches': {
                'type': 'number',
                'description': 'Turns in this session that matched.',
              },
              'match': {
                'type': 'string',
                'enum': ['phrase', 'allWords', 'repaired', 'anyWord'],
              },
              'indexedAt': {
                'type': 'string',
                'description':
                    'When the transcript was last read. Anything said after '
                    'it is not searchable yet.',
              },
            },
            'required': [
              'sessionId',
              'conversationId',
              'title',
              'excerpt',
              'role',
              'matches',
            ],
          },
        },
        'nextCursor': {
          'type': ['string', 'null'],
        },
        'note': {'type': 'string'},
      },
      'required': ['query', 'results', 'nextCursor', 'note'],
    },
  },
];
