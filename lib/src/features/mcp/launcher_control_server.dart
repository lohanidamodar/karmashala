import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';
import '../agents/domain/agent_kind.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';

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
}
