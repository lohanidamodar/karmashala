import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';
import '../../core/process/command_runner_providers.dart';
import '../agents/application/agent_installations_controller.dart';
import '../agents/application/agent_providers.dart';
import '../agents/application/agent_usage_providers.dart';
import '../agents/domain/agent_installation.dart';
import '../agents/domain/agent_kind.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../environments/application/environment_providers.dart';
import '../environments/domain/environment_kind.dart';
import '../environments/domain/environment_path.dart';
import '../environments/domain/execution_environment.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';
import '../repositories/domain/repository.dart';
import '../sessions/application/session_actions.dart';
import '../settings/application/settings_controller.dart';
import '../settings/domain/permission_mode.dart';
import '../terminal/application/system_terminal_providers.dart';
import '../terminal/data/system_terminal_service.dart';
import 'tmux_orchestration.dart';

/// A loopback HTTP server that exposes chitragupta's data and actions to the
/// launcher agent's MCP bridge (see `--mcp-serve`).
///
/// The bridge process (spawned by the agent CLI) is a thin translator with no
/// database or plugin dependencies; it forwards each MCP `tools/call` here as a
/// `POST /rpc` and the real work runs against the live Riverpod container. The
/// server binds to 127.0.0.1 on an ephemeral port and requires a bearer token,
/// both written to a `mcp_bridge.json` file only readable locally, so nothing
/// on the network can reach it.
class LauncherControlServer {
  LauncherControlServer(this._container, {AppLogger? logger})
    : _logger = logger ?? AppLogger.named('mcp-control');

  final ProviderContainer _container;
  final AppLogger _logger;

  HttpServer? _server;
  String? _token;

  /// Where the bridge reads the port + token from.
  static Future<String> bridgeFilePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'mcp_bridge.json');
  }

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _token = _generateToken();
    await _writeBridgeFile(server.port, _token!);
    server.listen(_handle, onError: (Object e) => _logger.warning('$e'));
    _logger.info('Launcher control server on 127.0.0.1:${server.port}.');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _writeBridgeFile(int port, String token) async {
    final file = File(await bridgeFilePath());
    await file.writeAsString(
      jsonEncode({'port': port, 'token': token, 'pid': pid}),
      flush: true,
    );
  }

  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.headers.value('authorization') != 'Bearer $_token') {
        response.statusCode = HttpStatus.unauthorized;
        await response.close();
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/rpc') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final tool = payload['tool'] as String?;
      final args =
          (payload['arguments'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final result = await _dispatch(tool, args);
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'ok': true, 'result': result}));
      await response.close();
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'ok': false, 'error': '$e'}));
      await response.close();
    }
  }

  Future<Object?> _dispatch(String? tool, Map<String, dynamic> args) async {
    switch (tool) {
      // Meta-call: the MCP bridge fetches tool schemas from here so there is a
      // single source of truth for the tool list.
      case '__list_tools__':
        return toolSchemas;
      case 'list_projects':
        return _listProjects();
      case 'list_sessions':
        return _listSessions(
          query: args['query'] as String?,
          cli: args['cli'] as String?,
        );
      case 'list_agents':
        return _listAgents();
      case 'get_usage':
        return _getUsage(
          cli: args['cli'] as String?,
          environmentId: args['environmentId'] as String?,
        );
      case 'open_new_session':
        return _openNewSession(
          projectId: args['projectId'] as String?,
          cli: args['cli'] as String?,
          agentInstallationId: args['agentInstallationId'] as String?,
          repositoryId: args['repositoryId'] as String?,
        );
      case 'open_session':
        return _openSession(args['id'] as String?);
      case 'open_sessions_in_tmux':
        return _openSessionsInTmux(
          (args['ids'] as List?)?.whereType<String>().toList() ??
              const <String>[],
          name: args['name'] as String?,
        );
      default:
        throw ArgumentError('Unknown tool: $tool');
    }
  }

  /// MCP tool definitions (name/description/inputSchema) served to the bridge.
  static const List<Map<String, dynamic>> toolSchemas = [
    {
      'name': 'list_projects',
      'description':
          'List the projects known to Chitragupta (name, environment, path).',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    },
    {
      'name': 'list_sessions',
      'description':
          'List coding-agent sessions. Optionally filter by a case-insensitive '
          'substring (matched against project, repository, title, and preview) '
          'and by CLI ("claude" or "codex").',
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
      'name': 'open_new_session',
      'description':
          'Start a NEW agent session (not a resume) in a project, in a new '
          'terminal. Choose the agent with agentInstallationId (from '
          'list_agents) or cli ("claude"/"codex"); omit both to use the '
          "configured default. repositoryId is optional (defaults to the "
          "project's first repository). The agent must be installed in the "
          "project's environment.",
      'inputSchema': {
        'type': 'object',
        'properties': {
          'projectId': {
            'type': 'string',
            'description': 'Project id from list_projects.',
          },
          'cli': {
            'type': 'string',
            'description': 'Agent CLI to use: "claude" or "codex".',
          },
          'agentInstallationId': {
            'type': 'string',
            'description': 'Specific installation id from list_agents.',
          },
          'repositoryId': {'type': 'string'},
        },
        'required': ['projectId'],
      },
    },
    {
      'name': 'get_usage',
      'description':
          'Get current usage/limit percentages for an agent. cli is "claude" '
          'or "codex"; environmentId is optional (defaults to the first '
          'matching installation).',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'cli': {'type': 'string'},
          'environmentId': {'type': 'string'},
        },
        'required': ['cli'],
      },
    },
    {
      'name': 'open_session',
      'description':
          'Open one session by its id in a new external terminal, resuming it.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'Session id from list_sessions.',
          },
        },
        'required': ['id'],
      },
    },
    {
      'name': 'open_sessions_in_tmux',
      'description':
          'Open several sessions together as windows in a single tmux session '
          '(WSL), in one new terminal tab. All sessions must live in the same '
          'WSL distribution. Pass the session ids from list_sessions. '
          'Non-destructive: if a tmux session with the given name already '
          'exists it is NOT killed — the sessions are appended as new windows '
          'without switching the focused window of any running tab.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'ids': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Session ids to open together.',
          },
          'name': {
            'type': 'string',
            'description': 'Optional tmux session name.',
          },
        },
        'required': ['ids'],
      },
    },
  ];

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
    final wantCli = _parseCli(cli);

    final sessions = <Map<String, dynamic>>[];
    for (final project in projects) {
      for (final repo in repositoryDao.getByProject(project.id)) {
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
            'externalId': session.externalId,
            'title': session.displayTitle,
            'cli': session.cli.name,
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

  AgentKind? _parseCli(String? cli) {
    if (cli == null) return null;
    final normalized = cli.trim().toLowerCase();
    for (final kind in AgentKind.values) {
      if (kind.name.toLowerCase() == normalized) return kind;
    }
    if (normalized == 'claude' || normalized == 'claude code') {
      return AgentKind.claudeCode;
    }
    return null;
  }

  List<Map<String, dynamic>> _listAgents() {
    return [
      for (final install
          in _container.read(agentInstallationDaoProvider).getAll())
        {
          'agentInstallationId': install.id,
          'cli': install.agentKind.name,
          'environmentId': install.environmentId,
          if (install.version != null) 'version': install.version,
          'path': install.executable.path,
        },
    ];
  }

  Future<Object?> _openNewSession({
    String? projectId,
    String? cli,
    String? agentInstallationId,
    String? repositoryId,
  }) async {
    if (projectId == null) throw ArgumentError('Missing projectId.');
    final repos = _container
        .read(repositoryDaoProvider)
        .getByProject(projectId);
    if (repos.isEmpty) {
      throw StateError('This project has no repositories to run in.');
    }
    Repository repo;
    if (repositoryId != null) {
      repo = repos.firstWhere(
        (r) => r.id == repositoryId,
        orElse: () => throw StateError('Repository not found in this project.'),
      );
    } else {
      repo = repos.first;
    }

    final installs = _container
        .read(agentInstallationDaoProvider)
        .getByEnvironment(repo.path.environmentId);
    if (installs.isEmpty) {
      throw StateError('No agent is installed in ${repo.path.environmentId}.');
    }
    AgentInstallation? install;
    if (agentInstallationId != null) {
      for (final i in installs) {
        if (i.id == agentInstallationId) {
          install = i;
          break;
        }
      }
      if (install == null) {
        throw StateError(
          'That agent installation is not available in this project.',
        );
      }
    } else if (cli != null) {
      final kind = _parseCli(cli);
      for (final i in installs) {
        if (i.agentKind == kind) {
          install = i;
          break;
        }
      }
      if (install == null) {
        throw StateError(
          '$cli is not installed in ${repo.path.environmentId}.',
        );
      }
    } else {
      final settings = _container.read(settingsControllerProvider);
      install =
          resolveDefaultInstallation(
            installs,
            defaultInstallationId: settings.defaultAgentInstallationId,
            defaultKind: settings.defaultAgent,
          ) ??
          installs.first;
    }

    final terminal = await _container.read(
      defaultSystemTerminalProvider.future,
    );
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    await _container
        .read(sessionActionsProvider)
        .startNewInSystemTerminal(
          repo: repo,
          installation: install,
          terminal: terminal,
        );
    return {
      'opened': 'new ${install.agentKind.name} session',
      'repository': repo.name,
      'environmentId': repo.path.environmentId,
    };
  }

  Future<Object?> _getUsage({String? cli, String? environmentId}) async {
    final kind = _parseCli(cli) ?? AgentKind.claudeCode;
    final install = _installFor(kind, environmentId);
    if (install == null) {
      throw StateError('No ${kind.name} installation found.');
    }
    final environments = _container
        .read(executionEnvironmentDaoProvider)
        .getAll();
    final usage = await _container
        .read(agentUsageServiceProvider)
        .fetch(install, environments);
    return {
      'environmentId': install.environmentId,
      'windows': [
        for (final w in usage.windows)
          {
            'label': w.label,
            'percent': w.percent,
            if (w.resetsAt != null) 'resetsAt': w.resetsAt!.toIso8601String(),
          },
      ],
    };
  }

  Future<Object?> _openSession(String? id) async {
    if (id == null) throw ArgumentError('Missing session id.');
    final session = _container.read(importedSessionDaoProvider).getById(id);
    if (session == null) throw StateError('Session not found: $id');
    final repo = _container
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    final env = _container
        .read(executionEnvironmentDaoProvider)
        .getById(session.environmentId);
    final install = _installFor(session.cli, session.environmentId);
    if (repo == null || env == null || install == null) {
      throw StateError('Session repository, environment, or agent is missing.');
    }
    final terminal = await _container.read(
      defaultSystemTerminalProvider.future,
    );
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    final command = resumeCommandLine(
      agentExecutable: install.executable.path,
      cli: session.cli.name,
      externalId: session.externalId,
      environment: env,
      cwd: repo.path,
      permissionMode: _permissionFor(session.cli),
    );
    await _container
        .read(systemTerminalServiceProvider)
        .launch(
          terminal,
          command: command,
          workingDirectory: env.wslDistribution == null ? repo.path.path : null,
        );
    return {'opened': session.displayTitle, 'environmentId': env.id};
  }

  Future<Object?> _openSessionsInTmux(List<String> ids, {String? name}) async {
    if (ids.isEmpty) throw ArgumentError('No session ids given.');
    final importedDao = _container.read(importedSessionDaoProvider);
    final repositoryDao = _container.read(repositoryDaoProvider);
    final envDao = _container.read(executionEnvironmentDaoProvider);

    final windows = <TmuxWindow>[];
    ExecutionEnvironment? distroEnv;
    for (final id in ids) {
      final session = importedDao.getById(id);
      if (session == null) throw StateError('Session not found: $id');
      final env = envDao.getById(session.environmentId);
      if (env == null || env.wslDistribution == null) {
        throw StateError(
          'Session "${session.displayTitle}" is not in a WSL environment; '
          'tmux grouping requires WSL sessions.',
        );
      }
      distroEnv ??= env;
      if (env.id != distroEnv.id) {
        throw StateError(
          'All sessions must be in the same WSL distribution '
          '(${distroEnv.wslDistribution}).',
        );
      }
      final repo = repositoryDao.getById(session.repositoryId);
      final install = _installFor(session.cli, session.environmentId);
      if (repo == null || install == null) {
        throw StateError('Repository or agent missing for "$id".');
      }
      final parts = [
        install.executable.path,
        ...permissionArgsFor(session.cli.name, _permissionFor(session.cli)),
        ...switch (session.cli) {
          AgentKind.codex => ['resume', session.externalId],
          _ => ['--resume', session.externalId],
        },
      ];
      windows.add(
        TmuxWindow(
          label: tmuxSafeName(session.displayTitle, fallback: 'session'),
          cwd: repo.path.path,
          command: parts.join(' '),
        ),
      );
    }

    final env = distroEnv!;
    final sessionName = tmuxSafeName(name ?? 'chitragupta', fallback: 'cg');
    final script = buildTmuxScript(sessionName, windows);

    // Write the script into the distro's /tmp via its UNC path, so nothing has
    // to survive quoting through the terminal → wsl → bash chain.
    final scriptWslPath =
        '/tmp/chitragupta-tmux-${Random().nextInt(1 << 32)}.sh';
    final windowsEnv = _windowsEnv();
    if (windowsEnv == null) throw StateError('No Windows host environment.');
    final uncPath = _container
        .read(pathTranslatorProvider)
        .translate(
          EnvironmentPath(environmentId: env.id, path: scriptWslPath),
          from: env,
          to: windowsEnv,
        )
        .path;
    await File(uncPath).writeAsString(script, flush: true);

    final terminal = await _container.read(
      defaultSystemTerminalProvider.future,
    );
    if (terminal == null) {
      throw StateError('No external terminal is configured.');
    }
    await _container
        .read(systemTerminalServiceProvider)
        .launch(
          terminal,
          command: [
            'wsl.exe',
            '-d',
            env.wslDistribution!,
            '--',
            'bash',
            scriptWslPath,
          ],
        );
    return {'opened': windows.length, 'tmuxSession': sessionName};
  }

  AgentInstallation? _installFor(AgentKind kind, String? environmentId) {
    for (final install
        in _container.read(agentInstallationDaoProvider).getAll()) {
      if (install.agentKind != kind) continue;
      if (environmentId != null && install.environmentId != environmentId) {
        continue;
      }
      return install;
    }
    return null;
  }

  ExecutionEnvironment? _windowsEnv() {
    for (final env
        in _container.read(executionEnvironmentDaoProvider).getAll()) {
      if (env.kind == EnvironmentKind.windowsNative) return env;
    }
    return null;
  }

  PermissionMode _permissionFor(AgentKind kind) => _container
      .read(settingsControllerProvider)
      .permissionsFor(kind)
      .existingSessions;
}
