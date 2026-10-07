import 'package:agent_cli/discovery.dart' show AgentInstallation;
import 'package:agent_cli/read.dart'
    show conversationQueryTokens, kConversationQueryMinimum;
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_conversations/karmashala_conversations.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/karmashala_environments.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart';

import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// `list_projects`, `list_sessions`, `list_agents`, `session_search`: what
/// exists — the projects, the sessions in them, the agents installed to run
/// one — and what was said in every conversation. None needs the caller's
/// identity: they describe the machine, read from the store and the
/// server's own conversation index.
class InventoryToolSet extends ServerToolSet {
  InventoryToolSet(this._context)
    : _projects = ProjectDao(_context.database),
      _repositories = RepositoryDao(_context.database),
      _sessions = SessionDao(_context.database),
      _imported = ImportedSessionDao(_context.database),
      _installations = AgentInstallationDao(_context.database),
      _resumes = ScheduledResumeDao(_context.database);

  final ServerToolContext _context;
  final ProjectDao _projects;
  final RepositoryDao _repositories;
  final SessionDao _sessions;
  final ImportedSessionDao _imported;
  final AgentInstallationDao _installations;
  final ScheduledResumeDao _resumes;

  @override
  List<Map<String, Object?>> get schemas => inventoryToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(
    () => switch (tool) {
      'list_projects' => _listProjects(),
      'list_sessions' => _listSessions(
        query: arguments['query'] as String?,
        cli: arguments['cli'] as String?,
      ),
      'list_agents' => _listAgents(),
      'session_search' => _search(arguments),
      _ => throw ArgumentError('Unknown tool: $tool'),
    },
  );

  /// The registry's id for a CLI name a caller wrote — its id, or a name its
  /// adapter declares — or null when nothing matches it.
  String? parseCli(String? cli) {
    if (cli == null) return null;
    final normalized = cli.trim().toLowerCase();
    final adapters = _context.agents.adapters;
    for (final adapter in adapters) {
      if (adapter.id.toLowerCase() == normalized) return adapter.id;
    }
    for (final adapter in adapters) {
      if (adapter.aliases.contains(normalized)) return adapter.id;
    }
    return null;
  }

  List<Map<String, Object?>> _listProjects() => [
    for (final project in _projects.getAll()..sort(compareProjects))
      {
        'id': project.id,
        'name': project.name,
        'environmentId': project.environmentId,
        'path': project.root.path,
        if (project.kind != null) 'kind': project.kind,
      },
  ];

  List<Map<String, Object?>> _listSessions({String? query, String? cli}) {
    final needle = query ?? '';
    final wantCli = parseCli(cli);
    final repositories = _repositories.getAll()..sort(compareRepositories);

    // Read-only: an agent can see a resume is waiting, never arm one.
    final resumes = {
      for (final resume in _resumes.live()) resume.sessionId: resume,
    };

    bool wanted(List<String> haystack) =>
        matchesSearch(needle, haystack.join(' '));

    final sessions = <Map<String, Object?>>[];
    for (final project in _projects.getAll()..sort(compareProjects)) {
      for (final repo in repositories) {
        if (repo.projectId != project.id) continue;
        // Sessions started in Karmashala, then the history imported beside
        // them.
        for (final session in _sessions.getByRepository(repo.id)) {
          final agentId =
              _installations.getById(session.agentInstallationId)?.agentId ??
              '';
          if (wantCli != null && agentId != wantCli) continue;
          if (!wanted([project.name, repo.name, session.title])) continue;
          sessions.add({
            'id': session.id,
            'kind': 'native',
            if (session.externalSessionId != null)
              'externalId': session.externalSessionId,
            'title': session.title,
            'cli': agentId,
            'agent': _context.agents.displayNameFor(agentId),
            'project': project.name,
            'repository': repo.name,
            'environmentId': repo.path.environmentId,
            'status': session.status.name,
            // What its agent last said it runs, never a setting.
            'model': _context.modelOf(session.id),
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
        for (final session in _imported.getByRepository(repo.id)) {
          if (wantCli != null && session.cli != wantCli) continue;
          if (!wanted([
            project.name,
            repo.name,
            session.title ?? '',
            session.preview,
          ])) {
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

  List<Map<String, Object?>> _listAgents() => [
    for (final install in _installations.getAll()..sort(compareInstallations))
      agentRow(install),
  ];

  /// One installation as `list_agents` gives it: one row per form, each
  /// naming the agent it is a form of, so a caller can say "Claude Code,
  /// chat" and still pass the installation to `open_new_session`.
  Map<String, Object?> agentRow(AgentInstallation install) => {
    'agentInstallationId': install.id,
    'cli': install.agentId,
    'agent': _context.agents.foldedNameOf(install.agentId),
    'form': _context.agents.formOf(install.agentId).name,
    'environmentId': install.environmentId,
    if (install.version != null) 'version': install.version,
    'path': install.executable.path,
  };

  /// Full-text search over what was said in every conversation, asked of the
  /// server's index as quick open asks it. Catches the running sessions up
  /// first.
  Future<Map<String, Object?>> _search(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (conversationQueryTokens(query) == null) {
      throw ArgumentError(
        'query is required: at least $kConversationQueryMinimum characters '
        'with a letter or digit in them.',
      );
    }
    final cliArg = args['cli'] as String?;
    final cli = parseCli(cliArg);
    if (cliArg != null && cliArg.trim().isNotEmpty && cli == null) {
      throw ArgumentError('Unknown cli "$cliArg". list_agents has the ids.');
    }
    String? conversationId;
    final sessionId = (args['sessionId'] as String?)?.trim();
    if (sessionId != null && sessionId.isNotEmpty) {
      conversationId =
          _sessions.getById(sessionId)?.externalSessionId ??
          _imported.getById(sessionId)?.externalId;
      if (conversationId == null) {
        throw ArgumentError(
          'No session with id $sessionId, or it has no conversation recorded '
          'yet. list_sessions has the ids.',
        );
      }
    }
    final limit = ((args['limit'] as num?)?.round() ?? 10).clamp(1, 50);
    final filter = SessionSearchFilter(
      conversationId: conversationId,
      cli: cli,
      projectId: args['projectId'] as String?,
      repositoryId: args['repositoryId'] as String?,
      after: _instant(args['after'], 'after'),
      before: _instant(args['before'], 'before'),
    );
    try {
      await _context.writeLater(const ConversationsCatchUp());
    } on DataRefused {
      // Searched as indexed: a catch-up is a nicety, the index is the answer.
    }
    final SessionSearchPage page;
    try {
      page = _context.write(
        ConversationsSearch(
          query,
          filter: filter,
          limit: limit,
          cursor: args['cursor'] as String?,
        ),
      );
    } on DataRefused catch (refused) {
      // A stale or foreign cursor is the caller's to fix; anything else is
      // the server's.
      if (refused.code == DataRefusalCode.invalid) {
        throw StateError(refused.message);
      }
      rethrow;
    }
    final results = <Map<String, Object?>>[];
    for (final hit in page.hits) {
      final native = _sessions.getByExternalSessionId(hit.sessionId);
      final imported = native == null
          ? _imported.getByExternal(hit.cli, hit.sessionId)
          : null;
      if (native == null && imported == null) continue;
      results.add({
        'sessionId': native?.id ?? imported!.id,
        'kind': native != null ? 'native' : 'imported',
        'conversationId': hit.sessionId,
        'title': native?.title ?? imported!.displayTitle,
        'cli': hit.cli,
        'agent': _context.agents.displayNameFor(hit.cli),
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
}

/// The schemas for [InventoryToolSet], as the app served them.
const List<Map<String, Object?>> inventoryToolSchemas = [
  {
    'name': 'list_projects',
    'description':
        'List the projects known to Karmashala (name, environment, path). '
        'A project with kind "scratch" is the folder sessions without a '
        'project run in, one per environment.',
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
        'to open_new_session, with the agent it is and its form: "terminal" '
        '(the CLI in a terminal) or "chat". An agent installed in both forms '
        'has a row for each. Use this to map a user request like "a codex '
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
