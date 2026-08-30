import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chitragupta_local_ipc/chitragupta_local_ipc.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_logger.dart';
import '../../core/process/command_runner_providers.dart';
import '../agents/application/agent_providers.dart';
import '../agents/application/agent_status_providers.dart';
import '../agents/application/agent_usage_providers.dart';
import '../agents/domain/agent_hook_endpoint.dart';
import '../agents/domain/agent_installation.dart';
import '../agents/domain/agent_ids.dart';
import '../browser/application/browser_providers.dart';
import '../browser/application/browser_tool_schemas.dart';
import '../browser/application/browser_tools.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../devices/application/device_providers.dart';
import '../devices/data/adb_service.dart';
import '../devices/domain/android_device.dart';
import '../devices/domain/device_input.dart';
import '../devices/domain/logcat_entry.dart';
import '../devices/domain/ui_node.dart';
import '../devices/domain/ui_summary.dart';
import '../environments/application/environment_providers.dart';
import '../fanout/application/comparison_providers.dart';
import '../environments/domain/environment_kind.dart';
import '../environments/domain/environment_path.dart';
import '../environments/domain/execution_environment.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';
import '../repositories/domain/repository.dart';
import '../sessions/application/session_launcher.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/domain/session.dart';
import '../sessions/domain/session_launch.dart';
import '../settings/domain/permission_mode.dart';
import '../terminal/application/system_terminal_providers.dart';
import '../terminal/data/system_terminal_service.dart';
import 'handshake_file_permissions.dart';
import 'tmux_orchestration.dart';

/// A loopback HTTP server that exposes chitragupta's data and actions to the
/// launcher agent's MCP bridge (see `--mcp-serve`).
///
/// The bridge process (spawned by the agent CLI) is a thin translator with no
/// database or plugin dependencies; it forwards each MCP `tools/call` here as a
/// `POST /rpc` and the real work runs against the live Riverpod container.
///
/// It also hosts `POST /agent-hook`, the callback endpoint agents' installed
/// hooks post status events to. That route needs exactly this transport —
/// loopback, ephemeral port, bearer token, handshake file — so it lives here
/// rather than in a second [HttpServer] of its own. All of its decision-making
/// stays in the transport-free [AgentHookReceiver].
///
/// ## Threat model
///
/// **What the boundary actually is: the bearer tokens, and the file permissions
/// on the handshake file that publishes them.** Nothing else.
///
/// The server binds `127.0.0.1` on an ephemeral port. That keeps it off the
/// network — no other *machine* can reach it — but it is worth being precise
/// about what loopback does *not* buy, because it is easy to read "127.0.0.1"
/// as if it were an access-control decision:
///
/// * **Any local process may connect.** Loopback TCP has no peer credentials and
///   no owner. Every process on the machine, running as any user, can open a
///   socket to the port and attempt auth. The ephemeral port is not a secret
///   either — `netstat -ano` lists it, along with the owning pid.
/// * **So the tokens are the whole boundary**, and the handshake file
///   (`mcp_bridge.json`, in the application-support directory) is the only thing
///   keeping them from any account on the box. That file is explicitly restricted
///   at write time — see [restrictHandshakeFileToCurrentUser], which also records
///   what the audited default ACL was and why an inherited one was not enough.
/// * **The `/agent-hook` token is deliberately weaker, and is not confidential
///   against local processes.** It is pasted verbatim into a `curl` command in
///   the agent's own config file, so it appears in that file *and* in the command
///   line of every hook invocation — readable by anything that can enumerate
///   processes. That is why it is a second, separate token: `/agent-hook` can
///   only report status, while the `/rpc` token opens sessions, launches
///   terminals and drives attached devices. Treat the hook token as public to
///   anything running as this user; treat the `/rpc` token as a real secret.
/// * **A process running as this user is inside the boundary, by construction.**
///   It can read the handshake file, and it could already do everything the API
///   offers by running the same commands directly. Local-user isolation is not a
///   goal here and cannot be one.
///
/// ## Split transport
///
/// Privileged `/rpc` calls use a **unix domain socket**, on all three
/// platforms, living in a directory restricted to the current user
/// ([restrictDirectoryToCurrentUser]). Unlike loopback TCP that is a real
/// access-control decision: a process running as another unprivileged user
/// cannot traverse to the socket at all, so it never gets as far as presenting
/// a token. `/rpc` over HTTP is disabled whenever the socket is up, and stays
/// disabled if the socket could not be bound — failing closed rather than
/// silently downgrading privileged RPC to a transport every local process can
/// reach.
///
/// This replaced a Windows-only named pipe. The pipe's DACL gave the same
/// boundary, but it left Linux and macOS on loopback TCP, and its blocking-FFI
/// serving isolate could not be shut down: Loop 48 measured a build with the
/// pipe running failing to exit at all on quit (>120 s), against 322 ms for the
/// same build without it.
///
/// Agent hooks remain on loopback HTTP, deliberately. The hook command is
/// `curl -sS -m 2 -X POST … http://127.0.0.1:<port>/agent-hook`, written into
/// third-party agents' own config files and run by whatever `curl` those agents
/// find — including agents running in WSL or over SSH, for which a Windows
/// socket path is not a reachable name at all. Their token is separate and
/// low-privilege (status reports only), and is already public to anything that
/// can list process command lines; that is the threat model above, and moving
/// the route would not improve it.
class LauncherControlServer {
  LauncherControlServer(this._container, {AppLogger? logger})
    : _logger = logger ?? AppLogger.named('mcp-control');

  final ProviderContainer _container;
  final AppLogger _logger;

  HttpServer? _server;
  LocalRpcServer? _socketServer;
  bool _httpRpcEnabled = false;
  String? _token;
  AgentHookEndpoint? _hookEndpoint;
  String? _publishedBridgePath;

  static const _maxRequestBytes = 1024 * 1024;

  /// Where agents' installed hooks post to, once [start] has bound the port;
  /// `null` before that. The hook installer writes this into the agent's own
  /// config file.
  AgentHookEndpoint? get hookEndpoint => _hookEndpoint;

  /// Where the bridge reads the port + token from.
  static Future<String> bridgeFilePath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'mcp_bridge.json');
  }

  /// Binds the server and writes the handshake file. Pass [bridgeFilePath] to
  /// control where that file goes (tests do); by default it is
  /// `mcp_bridge.json` in the application-support directory.
  ///
  /// [useLocalSocket] is the owner-only `/rpc` transport. Tests turn it off to
  /// exercise the HTTP fallback; nothing in the app does.
  Future<void> start({
    String? bridgeFilePath,
    bool useLocalSocket = true,
    String? socketDirectory,
  }) async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _token = _generateToken();
    // A *separate* token for /agent-hook. It is pasted verbatim into a curl
    // command in the agent's own config file, so it also shows up in process
    // command lines; the /rpc token opens sessions and drives devices, and must
    // not be exposed that widely.
    _hookEndpoint = AgentHookEndpoint(
      port: server.port,
      token: _generateToken(),
    );
    _httpRpcEnabled = !useLocalSocket;
    if (useLocalSocket) {
      try {
        _socketServer = await _bindLocalSocket(socketDirectory);
      } on Object catch (error, stack) {
        // Fail closed: hooks still work, but privileged RPC is not silently
        // downgraded to loopback when the owner-only transport cannot start.
        _logger.warning('Owner-only RPC socket failed to start.', error, stack);
      }
    }
    await _writeBridgeFile(server.port, _token!, bridgeFilePath);
    server.listen(_handle, onError: (Object e) => _logger.warning('$e'));
    _logger.info('Launcher control server on 127.0.0.1:${server.port}.');
  }

  /// Creates the owner-only directory and binds the RPC socket inside it.
  ///
  /// The directory is restricted **before** the socket is created, so there is
  /// no window in which the socket exists under a permissive ACL.
  Future<LocalRpcServer> _bindLocalSocket(String? overrideDirectory) async {
    final dirPath =
        overrideDirectory ??
        p.join((await getApplicationSupportDirectory()).path, 'ipc');
    final dir = Directory(dirPath);
    await dir.create(recursive: true);
    await restrictDirectoryToCurrentUser(dir, logger: _logger);
    final socketPath = p.join(dir.path, 'rpc.sock');
    final socket = await LocalRpcServer.bind(socketPath, _handleSocketRpc);
    _logger.info('Owner-only RPC socket at $socketPath.');
    return socket;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    await _socketServer?.close();
    final published = _publishedBridgePath;
    if (published != null) {
      try {
        final file = File(published);
        if (await file.exists()) await file.delete();
      } on Object catch (error) {
        _logger.warning('Could not remove stale bridge handshake: $error');
      }
    }
    _server = null;
    _socketServer = null;
    _token = null;
    _hookEndpoint = null;
    _httpRpcEnabled = false;
    _publishedBridgePath = null;
  }

  /// Publishes the port and tokens for the bridge to read.
  ///
  /// The file is created **empty**, restricted, and only then written to, so the
  /// tokens never touch the disk under a permissive ACL — not even for the
  /// instant between `writeAsString` and a follow-up `icacls`. Any pre-existing
  /// file is removed first rather than overwritten, because a write preserves
  /// the DACL a file already carries.
  Future<void> _writeBridgeFile(
    int port,
    String token,
    String? overridePath,
  ) async {
    final file = File(overridePath ?? await bridgeFilePath());
    _publishedBridgePath = file.path;
    await file.parent.create(recursive: true);
    try {
      if (file.existsSync()) await file.delete();
    } catch (error) {
      // A bridge still holding it open; the restriction below covers us.
      _logger.warning('Could not replace the handshake file: $error');
    }
    await file.create();
    await restrictHandshakeFileToCurrentUser(file, logger: _logger);
    await file.writeAsString(
      jsonEncode({
        'port': port,
        'token': token,
        'pid': pid,
        'hookToken': _hookEndpoint!.token,
        if (_socketServer case final socket?) 'socketPath': socket.path,
      }),
      flush: true,
    );
  }

  /// 24 bytes (192 bits) from the platform CSPRNG, base64url-encoded.
  ///
  /// [Random.secure] and not [Random]: these are the entire access-control
  /// boundary (see the class doc), and a predictable token would let any local
  /// process skip needing to read the handshake file at all. 192 bits is far
  /// past what an unauthenticated attacker could search against a local HTTP
  /// server, and leaves room to spare against the birthday bound over the
  /// lifetime of a machine.
  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/agent-hook') {
      await _handleAgentHook(request);
      return;
    }
    final response = request.response;
    try {
      if (!_constantTimeEquals(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Bearer $_token',
      )) {
        response.statusCode = HttpStatus.unauthorized;
        await response.close();
        return;
      }
      if (request.method != 'POST' || request.uri.path != '/rpc') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      if (!_httpRpcEnabled) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final body = await _readBoundedBody(request);
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final tool = payload['tool'] as String?;
      final args =
          (payload['arguments'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      // Which of *our* sessions is calling, when one is.
      //
      // The bridge reads it from its own environment, which Chitragupta stamped
      // on the agent process when it opened the pane, so it describes the actual
      // process tree rather than something the model chose to say. That is what
      // makes the spawn-depth cap worth having: a tool argument would be a
      // number the caller could simply omit.
      final callerSessionId = payload['callerSessionId'] as String?;
      final result = await _dispatch(tool, args, callerSessionId);
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'ok': true, 'result': result}));
      await response.close();
    } catch (e) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode({'ok': false, 'error': '$e'}));
      await response.close();
    }
  }

  /// One `/rpc` call arriving over the owner-only socket.
  ///
  /// The directory ACL is the boundary, and the token is the second lock behind
  /// it: it costs a caller nothing that already reads the restricted handshake
  /// file, and it means a directory whose permissions were never applied — an
  /// `icacls` that failed, a filesystem that does not carry them — is not
  /// instantly an open door.
  Future<String> _handleSocketRpc(String body) async {
    try {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      if (!_constantTimeEquals(payload['token'] as String?, _token ?? '')) {
        return jsonEncode({'ok': false, 'error': 'Unauthorized.'});
      }
      final tool = payload['tool'] as String?;
      final args =
          (payload['arguments'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final callerSessionId = payload['callerSessionId'] as String?;
      final result = await _dispatch(tool, args, callerSessionId);
      return jsonEncode({'ok': true, 'result': result});
    } on Object catch (error) {
      return jsonEncode({'ok': false, 'error': '$error'});
    }
  }

  /// `POST /agent-hook?agent=<id>&event=<name>` — one callback from an agent's
  /// installed hook, with the hook's own JSON payload as the body.
  Future<void> _handleAgentHook(HttpRequest request) async {
    final response = request.response;
    final endpoint = _hookEndpoint;
    try {
      if (endpoint == null ||
          !_constantTimeEquals(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer ${endpoint.token}',
          )) {
        response.statusCode = HttpStatus.unauthorized;
        await response.close();
        return;
      }
      if (request.method != 'POST') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final body = await _readBoundedBody(request);
      final report = _container
          .read(agentHookReceiverProvider)
          .handle(
            agentId: request.uri.queryParameters['agent'],
            event: request.uri.queryParameters['event'],
            body: body,
          );
      // Always 200 on an authenticated callback, even for an event we do not
      // recognise: a hook must never block the agent that fired it.
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode({'ok': true, 'status': report.status.name}));
      await response.close();
    } catch (error) {
      _logger.warning('Agent hook callback failed: $error');
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    }
  }

  Future<String> _readBoundedBody(HttpRequest request) async {
    if (request.contentLength > _maxRequestBytes) {
      throw const FormatException('Request body exceeds the 1 MiB limit.');
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maxRequestBytes) {
        throw const FormatException('Request body exceeds the 1 MiB limit.');
      }
    }
    return utf8.decode(bytes);
  }

  bool _constantTimeEquals(String? actual, String expected) {
    if (actual == null) return false;
    var difference = actual.length ^ expected.length;
    final length = actual.length > expected.length
        ? actual.length
        : expected.length;
    for (var i = 0; i < length; i++) {
      final a = i < actual.length ? actual.codeUnitAt(i) : 0;
      final b = i < expected.length ? expected.codeUnitAt(i) : 0;
      difference |= a ^ b;
    }
    return difference == 0;
  }

  Future<Object?> _dispatch(
    String? tool,
    Map<String, dynamic> args, [
    String? callerSessionId,
  ]) async {
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
          title: args['title'] as String?,
          prompt: args['prompt'] as String?,
          useWorktree: args['useWorktree'] == true,
          callerSessionId: callerSessionId,
        );
      case 'open_session':
        return _openSession(args['id'] as String?);
      case 'fanout_list':
        return _fanOutList(
          repositoryId: args['repositoryId'] as String?,
          includeArchived: args['includeArchived'] == true,
          limit: (args['limit'] as num?)?.round(),
        );
      case 'fanout_get':
        return _fanOutGet(args['id'] as String?);
      case 'list_devices':
        return _listDevices();
      case 'device_screenshot':
        return _deviceScreenshot(args['serial'] as String?);
      case 'device_tap':
        return _deviceTap(
          args['serial'] as String?,
          (args['x'] as num?)?.round(),
          (args['y'] as num?)?.round(),
        );
      case 'device_type':
        return _deviceType(args['serial'] as String?, args['text'] as String?);
      case 'device_key':
        return _deviceKey(args['serial'] as String?, args['key'] as String?);
      case 'device_logcat':
        return _deviceLogcat(
          serial: args['serial'] as String?,
          packageName: args['package'] as String?,
          level: args['level'] as String?,
          lines: (args['lines'] as num?)?.round(),
        );
      case 'device_ui_dump':
        return _deviceUiDump(
          serial: args['serial'] as String?,
          full: args['full'] == true,
          filter: args['filter'] as String?,
          limit: (args['limit'] as num?)?.round(),
        );
      case 'device_find_elements':
        return _deviceFindElements(
          serial: args['serial'] as String?,
          query: _uiQuery(args),
          limit: (args['limit'] as num?)?.round(),
        );
      case 'device_tap_element':
        return _deviceTapElement(
          serial: args['serial'] as String?,
          query: _uiQuery(args),
          index: (args['index'] as num?)?.round(),
        );
      case 'device_stop_emulator':
        return _deviceStopEmulator(args['serial'] as String?);
      case 'open_sessions_in_tmux':
        return _openSessionsInTmux(
          (args['ids'] as List?)?.whereType<String>().toList() ??
              const <String>[],
          name: args['name'] as String?,
        );
      // The browser tools live in features/browser and share the app's single
      // BrowserService with the browser pane, so an agent and the developer
      // drive the same page.
      case final String name when BrowserTools.handles(name):
        return BrowserTools(
          _container.read(browserServiceProvider),
        ).call(name, args);
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
          'List coding-agent sessions — both the ones running in Chitragupta '
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
      'name': 'open_new_session',
      'description':
          'Start a NEW agent session (not a resume) in a project, as a terminal '
          'tab in Chitragupta. Choose the agent with agentInstallationId (from '
          'list_agents) or cli ("claude"/"codex"); omit both to use the '
          "configured default. repositoryId is optional (defaults to the "
          "project's first repository). The agent must be installed in the "
          "project's environment. Sessions you start this way are recorded as "
          'your children, and nesting is capped: if the call is refused for '
          'depth, do the work yourself instead of delegating it further.',
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
          'title': {
            'type': 'string',
            'description': 'Short name for the session, shown in the tab.',
          },
          'prompt': {
            'type': 'string',
            'description':
                'Opening instruction for the new agent. Sent as its first '
                'message, prefixed with a line naming this session.',
          },
          'useWorktree': {
            'type': 'boolean',
            'description':
                'Run in a dedicated Git worktree instead of the repository '
                'itself. Use this when the new session will edit files and you '
                'are still working in the same repository.',
          },
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
          'Open one session by its id. A Chitragupta session that is still '
          'running is reattached to a tab; anything else is resumed. Imported '
          'CLI sessions open in an external terminal.',
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
      'name': 'fanout_list',
      'description':
          'List the fan-out comparisons — one prompt run on several agents in '
          'parallel worktrees. Each row gives the prompt, when it ran, the '
          'outcome (pending/merged/discarded) and every candidate with its '
          'agent and diff stat. Comparisons persist: a merged one whose losing '
          'worktrees were deleted is still listed. Use fanout_get for the full '
          'record of one.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'repositoryId': {
            'type': 'string',
            'description': 'Only comparisons for this repository.',
          },
          'includeArchived': {
            'type': 'boolean',
            'description': 'Include comparisons the user archived.',
          },
          'limit': {
            'type': 'number',
            'description': 'Most recent N (default 20).',
          },
        },
      },
    },
    {
      'name': 'fanout_get',
      'description':
          'The full record of one fan-out comparison: the prompt, the winner, '
          'the merge commit, and every candidate with its session, branch, '
          'worktree (and whether that worktree has been removed), diff stat, '
          'verification verdict and failure reason. Use this to report on a '
          'comparison the user ran.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'string',
            'description': 'Comparison id, from fanout_list.',
          },
        },
        'required': ['id'],
      },
    },
    {
      'name': 'list_devices',
      'description':
          'List connected Android devices and running emulators, with their '
          'serial, model, and whether they are ready. Devices that are not '
          'usable (unauthorized, offline) are included and marked so you can '
          'explain the problem rather than reporting no devices.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    },
    {
      'name': 'device_screenshot',
      'description':
          'Capture the current screen of an Android device as a PNG image. '
          'Use this to see what an app is actually showing. serial is optional '
          'when exactly one device is connected.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {
            'type': 'string',
            'description': 'Device serial from list_devices.',
          },
        },
      },
    },
    {
      'name': 'device_tap',
      'description':
          'Tap the device screen at (x, y) in DEVICE pixel coordinates (the '
          'coordinate space reported by list_devices as screen size, not the '
          'size of any screenshot you scaled). Take a screenshot first to '
          'decide where to tap.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'x': {'type': 'number', 'description': 'X in device pixels.'},
          'y': {'type': 'number', 'description': 'Y in device pixels.'},
        },
        'required': ['x', 'y'],
      },
    },
    {
      'name': 'device_type',
      'description':
          'Type text into whatever field currently has focus on the device. '
          'Tap the field first. Spaces and shell characters are escaped for you.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'text': {'type': 'string'},
        },
        'required': ['text'],
      },
    },
    {
      'name': 'device_key',
      'description':
          'Press a hardware button: back, home, recents, power, volumeUp, '
          'volumeDown, enter, tab or delete.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'key': {
            'type': 'string',
            'description':
                'back | home | recents | power | volumeUp | '
                'volumeDown | enter | tab | delete',
          },
        },
        'required': ['key'],
      },
    },
    {
      'name': 'device_logcat',
      'description':
          'Read recent logcat output, newest last. Filter to one app with '
          'package (strongly recommended — the unfiltered system log is huge '
          'and mostly noise), and raise level to see only warnings or errors. '
          'Returns nothing if the package is not running.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'package': {
            'type': 'string',
            'description': 'Application id, e.g. com.example.app.',
          },
          'level': {
            'type': 'string',
            'description':
                'Minimum level: verbose, debug, info, warning, error, fatal.',
          },
          'lines': {
            'type': 'number',
            'description': 'Max lines (default 200).',
          },
        },
      },
    },
    {
      'name': 'device_stop_emulator',
      'description':
          'Shut a running Android emulator down, freeing its memory and CPU. '
          'Emulators only — a physical device cannot be stopped this way. '
          'Anything the emulator has not written to a snapshot is lost.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {
            'type': 'string',
            'description': 'Emulator serial, e.g. emulator-5554.',
          },
        },
        'required': ['serial'],
      },
    },
    {
      'name': 'device_ui_dump',
      'description':
          'Read the accessibility (view) hierarchy of the current screen: what '
          'is on it, what each element says, and the exact point to tap for '
          'each one. Prefer this over device_screenshot when you intend to '
          'touch something — a screenshot cannot tell you what is tappable, '
          'and coordinates read off an image are guesswork. By default only '
          'nodes that carry text or accept input are listed; pass full=true '
          'for every node, including layout containers.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'full': {
            'type': 'boolean',
            'description':
                'Include every node instead of only the useful ones. Much '
                'larger; use it only when the default listing is missing '
                'something.',
          },
          'filter': {
            'type': 'string',
            'description':
                'Keep only nodes whose text, content-description, resource id '
                'or class contains this (case-insensitive).',
          },
          'limit': {
            'type': 'number',
            'description': 'Max nodes to list (default 200).',
          },
        },
      },
    },
    {
      'name': 'device_find_elements',
      'description':
          'Find elements on the current screen by text, resource id, '
          'content-description or class, and get the point to tap for each. '
          'Matching is case-insensitive and by substring unless exact=true. '
          'text matches BOTH the text and the content-description, which is '
          'what makes it work on Flutter apps: they put their labels in '
          'content-desc and leave text empty.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'text': {
            'type': 'string',
            'description': 'Visible text or content-description to look for.',
          },
          'resourceId': {
            'type': 'string',
            'description':
                'Resource id, in full (com.app:id/ok) or short (ok).',
          },
          'contentDesc': {
            'type': 'string',
            'description': 'Content-description only, ignoring text.',
          },
          'className': {
            'type': 'string',
            'description': 'Class, in full or by last segment (Button).',
          },
          'exact': {
            'type': 'boolean',
            'description': 'Require the whole value to match, not a substring.',
          },
          'clickable': {
            'type': 'boolean',
            'description': 'Keep only elements marked clickable.',
          },
          'limit': {
            'type': 'number',
            'description': 'Max matches (default 50).',
          },
        },
      },
    },
    {
      'name': 'device_tap_element',
      'description':
          'Tap the element matching a query rather than a coordinate — '
          'tap_element(text: "Sign in") instead of tap(357, 126). This is far '
          'more reliable: it survives layout changes, it cannot be off by a '
          'scale factor, and it tells you what it actually hit. It re-reads '
          'the hierarchy first, so it acts on the screen as it is now. '
          'Refuses rather than guessing when the query matches several '
          'elements (pass index) or nothing, and refuses to tap an element '
          'that is scrolled off screen.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'serial': {'type': 'string'},
          'text': {
            'type': 'string',
            'description': 'Visible text or content-description to tap.',
          },
          'resourceId': {'type': 'string'},
          'contentDesc': {'type': 'string'},
          'className': {'type': 'string'},
          'exact': {'type': 'boolean'},
          'clickable': {
            'type': 'boolean',
            'description': 'Only consider elements marked clickable.',
          },
          'index': {
            'type': 'number',
            'description':
                'Which match to tap (0-based) when the query is ambiguous.',
          },
        },
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
    ...browserToolSchemas,
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

  /// Fan-out comparisons, newest first. Compact by design: an agent asking
  /// "what did we try?" wants the shape, not every diff.
  List<Map<String, dynamic>> _fanOutList({
    String? repositoryId,
    bool includeArchived = false,
    int? limit,
  }) {
    final repositories = _container.read(repositoryDaoProvider);
    final comparisons = _container
        .read(comparisonDaoProvider)
        .getAll(repositoryId: repositoryId, includeArchived: includeArchived);
    final capped = comparisons.take(limit == null || limit <= 0 ? 20 : limit);
    return [
      for (final comparison in capped)
        {
          'id': comparison.id,
          'prompt': comparison.title,
          'repository': repositories.getById(comparison.repositoryId)?.name,
          'createdAt': comparison.createdAt.toIso8601String(),
          'outcome': comparison.outcome.name,
          'winner': comparison.winner?.agentId,
          'archived': comparison.archived,
          'candidates': [
            for (final candidate in comparison.candidates)
              {
                'agentId': candidate.agentId,
                'state': candidate.launch.name,
                'diff': candidate.diff?.summary,
              },
          ],
        },
    ];
  }

  /// One comparison in full — still without diff text, which is what
  /// `git diff` in the worktree is for while the worktree exists.
  Map<String, dynamic> _fanOutGet(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required.');
    }
    final comparison = _container.read(comparisonDaoProvider).getById(id);
    if (comparison == null) {
      throw ArgumentError('No comparison with id $id.');
    }
    final repository = _container
        .read(repositoryDaoProvider)
        .getById(comparison.repositoryId);
    return {
      'id': comparison.id,
      'prompt': comparison.prompt,
      'repository': repository?.name,
      'repositoryId': comparison.repositoryId,
      'createdAt': comparison.createdAt.toIso8601String(),
      'finishedAt': comparison.finishedAt?.toIso8601String(),
      'outcome': comparison.outcome.name,
      'mergedCommit': comparison.mergedCommit,
      'winnerAgentId': comparison.winner?.agentId,
      'archived': comparison.archived,
      'candidates': [
        for (final candidate in comparison.candidates)
          {
            'id': candidate.id,
            'agentId': candidate.agentId,
            'sessionId': candidate.sessionId,
            'state': candidate.launch.name,
            'isWinner': comparison.winnerCandidateId == candidate.id,
            'branch': candidate.branch,
            'worktree': candidate.worktree?.path,
            'worktreeRemoved': candidate.worktreeRemoved,
            if (candidate.diff case final diff?)
              'diff': {
                'summary': diff.summary,
                'filesChanged': diff.filesChanged,
                'insertions': diff.insertions,
                'deletions': diff.deletions,
                'commits': diff.commits,
                'capturedAt': diff.capturedAt.toIso8601String(),
              },
            if (candidate.evidence case final evidence?)
              'verdict': {
                'verdict': evidence.verdict.name,
                'label': evidence.label,
                'runId': evidence.runId,
              },
            'failure': candidate.failure,
            'notes': candidate.notes,
          },
      ],
    };
  }

  List<Map<String, dynamic>> _listSessions({String? query, String? cli}) {
    final projects = _container.read(projectsControllerProvider);
    final repositoryDao = _container.read(repositoryDaoProvider);
    final importedDao = _container.read(importedSessionDaoProvider);
    final needle = query?.trim().toLowerCase();
    final wantCli = _parseCli(cli);

    final sessionDao = _container.read(sessionDaoProvider);
    final registry = _container.read(agentRegistryProvider);
    final installDao = _container.read(agentInstallationDaoProvider);

    final sessions = <Map<String, dynamic>>[];
    for (final project in projects) {
      for (final repo in repositoryDao.getByProject(project.id)) {
        // Sessions started **in the app**. These were invisible here: every
        // session tool read only `imported_sessions`, so a session the user (or
        // another agent) started in Chitragupta could not be listed, opened or
        // grouped — the launcher agent saw a different world from the one on
        // screen (Loop 33 §6.9).
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

  String? _parseCli(String? cli) {
    if (cli == null) return null;
    final normalized = cli.trim().toLowerCase();
    for (final descriptor
        in _container.read(agentRegistryProvider).descriptors) {
      if (descriptor.id.toLowerCase() == normalized) return descriptor.id;
    }
    if (normalized == 'claude' || normalized == 'claude code') {
      return AgentIds.claudeCode;
    }
    return null;
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

  Future<Object?> _openNewSession({
    String? projectId,
    String? cli,
    String? agentInstallationId,
    String? repositoryId,
    String? title,
    String? prompt,
    bool useWorktree = false,
    String? callerSessionId,
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
      final agentId = _parseCli(cli);
      for (final i in installs) {
        if (i.agentId == agentId) {
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
      // The launcher's resolution, so "the default agent" means the same thing
      // here as it does in the New-session dialog and the mini launcher.
      install =
          _container
              .read(sessionLauncherProvider)
              .defaultInstallationIn(repo.path.environmentId) ??
          installs.first;
    }

    // Through the one launcher, exactly as the New-session dialog is. A session
    // an agent starts is not a second kind of session: same row, same PTY, same
    // permission resolution, same worktree option — and, because it has a row,
    // it is visible to `list_sessions` and reattachable, which a spawned
    // external terminal never was.
    //
    // This is also where the spawn-depth cap applies. `callerSessionId` comes
    // from the bridge's environment, not from the model.
    final launcher = _container.read(sessionLauncherProvider);
    try {
      final launched = await launcher.launch(
        SessionLaunchRequest(
          repository: repo,
          installation: install,
          title: (title == null || title.trim().isEmpty)
              ? 'Agent session'
              : title.trim(),
          purpose: SessionPurpose.newSession,
          useWorktree: useWorktree,
          firstMessage: prompt,
          parentSessionId: callerSessionId,
        ),
      );
      return {
        'sessionId': launched.session.id,
        'opened': 'new ${install.agentId} session',
        'title': launched.session.title,
        'repository': repo.name,
        'environmentId': repo.path.environmentId,
        'depth': launcher.depthForChildOf(callerSessionId).depth,
        if (launched.session.worktree != null)
          'worktree': launched.session.worktree!.path,
      };
    } on SessionDepthRefused catch (refused) {
      // Fail the caller's turn with the reason, rather than with a generic
      // error it might reasonably retry.
      throw StateError(refused.depth.refusal);
    }
  }

  Future<Object?> _getUsage({String? cli, String? environmentId}) async {
    final agentId = _parseCli(cli) ?? AgentIds.claudeCode;
    final install = _installFor(agentId, environmentId);
    if (install == null) {
      throw StateError('No $agentId installation found.');
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

    // A native session is reattached, not relaunched: it may still be running in
    // a pane, in which case "open" means bring its tab back — the same thing the
    // background-sessions list does. Only if nothing is live is it restarted,
    // through the one launcher, as a resume.
    final native = _container.read(sessionDaoProvider).getById(id);
    if (native != null) return _openNativeSession(native);

    final session = _container.read(importedSessionDaoProvider).getById(id);
    if (session == null) throw StateError('Session not found: $id');
    // An imported entry can name a conversation one of our own panes is still
    // running: open that, rather than putting a second agent on it.
    final launcher = _container.read(sessionLauncherProvider);
    final running = launcher.runningSessionWithExternalId(session.externalId);
    if (running != null && launcher.reveal(running.id)) {
      return {
        'opened': running.title,
        'sessionId': running.id,
        'reattached': true,
      };
    }
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
      cli: session.cli,
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

  Future<Object?> _openNativeSession(Session session) async {
    // The launcher owns "is it already running, and where" for every surface —
    // this used to be the only place that asked, which is why every other resume
    // path relaunched a session that had never stopped.
    if (_container.read(sessionLauncherProvider).reveal(session.id)) {
      return {
        'opened': session.title,
        'sessionId': session.id,
        'reattached': true,
      };
    }

    final repo = _container
        .read(repositoryDaoProvider)
        .getById(session.repositoryId);
    final install = _container
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId);
    if (repo == null || install == null) {
      throw StateError('Session repository or agent is missing.');
    }
    final launched = await _container
        .read(sessionLauncherProvider)
        .launch(
          SessionLaunchRequest(
            repository: repo,
            installation: install,
            title: session.title,
            purpose: SessionPurpose.existingSession,
            resumeExternalSessionId: session.externalSessionId,
          ),
        );
    return {
      'opened': launched.session.title,
      'sessionId': launched.session.id,
      'reattached': false,
    };
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
        ...permissionArgsFor(session.cli, _permissionFor(session.cli)),
        ...switch (session.cli) {
          AgentIds.codex => ['resume', session.externalId],
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

  // ---------------------------------------------------------------------------
  // Android devices
  //
  // These make the device pane usable by an agent: see the screen, touch it,
  // read the log. Everything goes through the same AdbService the pane uses, so
  // the agent and the human are driving exactly the same device.
  // ---------------------------------------------------------------------------

  AdbService _requireAdb() {
    final adb = _container.read(adbServiceProvider);
    if (adb == null) {
      throw StateError(
        'No Android SDK found. Set ANDROID_HOME or install the SDK to the '
        r'default location (%LOCALAPPDATA%\Android\Sdk).',
      );
    }
    return adb;
  }

  /// Resolves which device to act on. With exactly one ready device the serial
  /// can be omitted, which is what a caller will want almost every time.
  Future<AndroidDevice> _resolveDevice(String? serial) async {
    final devices = await _requireAdb().listDevices();
    if (devices.isEmpty) {
      throw StateError('No Android devices are connected.');
    }
    if (serial != null) {
      for (final device in devices) {
        if (device.serial == serial) {
          if (!device.isReady) {
            throw StateError(
              'Device $serial is ${device.state.name}, not ready. '
              'If it is unauthorized, accept the USB debugging prompt on the '
              'device.',
            );
          }
          return device;
        }
      }
      throw StateError('No device with serial $serial.');
    }
    final ready = devices.where((d) => d.isReady).toList();
    if (ready.isEmpty) {
      throw StateError(
        'No device is ready: '
        '${devices.map((d) => '${d.serial} (${d.state.name})').join(', ')}.',
      );
    }
    if (ready.length > 1) {
      throw StateError(
        'Several devices are connected; pass serial. Options: '
        '${ready.map((d) => d.serial).join(', ')}.',
      );
    }
    return ready.single;
  }

  Future<Object?> _listDevices() async {
    final adb = _requireAdb();
    final devices = await adb.listDevices();
    final avds = await adb.listAvds();
    return {
      'devices': [
        for (final device in devices)
          {
            'serial': device.serial,
            'name': device.displayName,
            'state': device.state.name,
            'ready': device.isReady,
            'emulator': device.isEmulator,
            'environmentId': device.environmentId,
            if (device.isReady)
              'screenSize': (await adb.screenSize(device.serial))?.toString(),
          },
      ],
      'avds': [
        for (final avd in avds) {'name': avd.name, 'running': avd.isRunning},
      ],
    };
  }

  Future<Object?> _deviceScreenshot(String? serial) async {
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final bytes = await adb.screenshot(device.serial);
    final size = await adb.screenSize(device.serial);
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'chitragupta_${device.serial}_${DateTime.now().millisecondsSinceEpoch}.png',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    // Returned as MCP content blocks so the model actually sees the image
    // instead of a wall of base64 in a JSON string.
    return {
      '_mcpContent': [
        {'type': 'image', 'data': base64Encode(bytes), 'mimeType': 'image/png'},
        {
          'type': 'text',
          'text':
              'Screenshot of ${device.displayName} (${device.serial})'
              '${size == null ? '' : ', screen $size device px'}. '
              'Saved to ${file.path}. Tap coordinates are in device pixels.',
        },
      ],
    };
  }

  Future<Object?> _deviceTap(String? serial, int? x, int? y) async {
    if (x == null || y == null) throw ArgumentError('x and y are required.');
    final device = await _resolveDevice(serial);
    await _requireAdb().tap(device.serial, x, y);
    return {'tapped': '($x, $y)', 'serial': device.serial};
  }

  Future<Object?> _deviceType(String? serial, String? text) async {
    if (text == null) throw ArgumentError('text is required.');
    final device = await _resolveDevice(serial);
    await _requireAdb().inputText(device.serial, text);
    return {'typed': text, 'serial': device.serial};
  }

  Future<Object?> _deviceKey(String? serial, String? key) async {
    if (key == null) throw ArgumentError('key is required.');
    final parsed = DeviceKey.parse(key);
    if (parsed == null) {
      throw ArgumentError(
        'Unknown key "$key". Valid keys: '
        '${DeviceKey.values.map((k) => k.name).join(', ')}.',
      );
    }
    final device = await _resolveDevice(serial);
    await _requireAdb().pressKey(device.serial, parsed);
    return {'pressed': parsed.name, 'serial': device.serial};
  }

  Future<Object?> _deviceLogcat({
    String? serial,
    String? packageName,
    String? level,
    int? lines,
  }) async {
    final device = await _resolveDevice(serial);
    final minLevel = _parseLogLevel(level) ?? LogLevel.verbose;
    final entries = await _requireAdb().readLogcat(
      device.serial,
      packageName: packageName,
      minLevel: minLevel,
      maxLines: lines ?? 200,
    );
    if (entries.isEmpty && packageName != null) {
      return {
        'serial': device.serial,
        'package': packageName,
        'lines': <String>[],
        'note': 'No output — $packageName does not appear to be running.',
      };
    }
    return {
      'serial': device.serial,
      'package': ?packageName,
      'lines': [for (final entry in entries) entry.toString()],
    };
  }

  // ---------------------------------------------------------------------------
  // The accessibility tree
  //
  // `device_tap` needs coordinates, and the only way an agent could previously
  // get them was to read them off a screenshot — which cannot say what is
  // tappable, and is one scale factor away from tapping the wrong thing while
  // reporting success. These three tools hand it the view hierarchy instead:
  // what is on screen, and exactly where to hit it.
  // ---------------------------------------------------------------------------

  UiElementQuery _uiQuery(Map<String, dynamic> args) => UiElementQuery(
    text: args['text'] as String?,
    resourceId: args['resourceId'] as String?,
    contentDescription: args['contentDesc'] as String?,
    className: args['className'] as String?,
    exact: args['exact'] == true,
    clickableOnly: args['clickable'] == true,
  );

  /// One line naming the device, the foreground app and the coordinate space.
  String _uiHeader(
    AndroidDevice device,
    UiHierarchy tree,
    DeviceScreenSize? screen,
  ) =>
      '${device.serial} · ${tree.packageName ?? 'unknown package'} · '
      'screen ${screen ?? 'unknown'} device px · rotation ${tree.rotation}';

  Future<Object?> _deviceUiDump({
    String? serial,
    bool full = false,
    String? filter,
    int? limit,
  }) async {
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final tree = await adb.dumpUiHierarchy(device.serial);
    final screen = await adb.screenSize(device.serial);

    if (full && filter == null) {
      final body = renderUiTree(tree, screen: screen);
      return _uiText([
        'Full UI hierarchy · ${_uiHeader(device, tree, screen)}',
        '${tree.nodeCount} nodes, indented by depth.',
        uiListingLegend,
        '',
        body,
      ]);
    }

    var nodes = full ? tree.allNodes.toList() : interestingNodes(tree);
    if (filter != null && filter.trim().isNotEmpty) {
      final needle = filter.trim().toLowerCase();
      bool has(String value) => value.toLowerCase().contains(needle);
      nodes = [
        for (final node in nodes)
          if (has(node.text) ||
              has(node.contentDescription) ||
              has(node.resourceId) ||
              has(node.className))
            node,
      ];
    }
    final rendered = renderUiElements(
      nodes,
      screen: screen,
      limit: limit ?? 200,
    );
    return _uiText([
      'UI hierarchy · ${_uiHeader(device, tree, screen)}',
      '${rendered.shown} of ${tree.nodeCount} nodes'
          '${full ? '' : ' (text-bearing or interactable)'}'
          '${filter == null ? '' : ', filtered by "$filter"'}'
          '${rendered.truncated == 0 ? '.' : ', ${rendered.truncated} more not '
                    'shown — raise limit.'}',
      uiListingLegend,
      '',
      rendered.listing.isEmpty ? '(nothing matched)' : rendered.listing,
      '',
      'Tap one with device_tap_element(text: "…"), which re-reads the screen '
          'and hits the element itself. The coordinates above also work with '
          'device_tap.',
    ]);
  }

  Future<Object?> _deviceFindElements({
    String? serial,
    required UiElementQuery query,
    int? limit,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className. '
        'Use device_ui_dump to see the whole screen.',
      );
    }
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final tree = await adb.dumpUiHierarchy(device.serial);
    final screen = await adb.screenSize(device.serial);
    final matches = tree.find(query);
    if (matches.isEmpty) {
      return _uiText([
        'No element matches $query on ${_uiHeader(device, tree, screen)}',
        '',
        'What is on screen instead:',
        uiListingLegend,
        renderUiElements(
          interestingNodes(tree),
          screen: screen,
          limit: 60,
        ).listing,
      ]);
    }
    final rendered = renderUiElements(
      matches,
      screen: screen,
      limit: limit ?? 50,
    );
    return _uiText([
      '${matches.length} element${matches.length == 1 ? '' : 's'} match '
          '$query · ${_uiHeader(device, tree, screen)}',
      'Best match first; an exact label beats a substring.',
      uiListingLegend,
      '',
      rendered.listing,
    ]);
  }

  /// Shuts a running emulator down.
  ///
  /// The serial is required rather than inferred: every other device tool
  /// defaults to "the only ready device", and silently defaulting a destructive
  /// action is a different thing entirely.
  Future<Object?> _deviceStopEmulator(String? serial) async {
    if (serial == null || serial.trim().isEmpty) {
      throw ArgumentError('serial is required for device_stop_emulator.');
    }
    final adb = _requireAdb();
    final devices = await adb.listDevices();
    final device = devices.where((d) => d.serial == serial).firstOrNull;
    if (device == null) {
      throw StateError('No device with serial $serial.');
    }
    if (!device.isEmulator) {
      throw StateError(
        '$serial is a physical device. Only emulators can be stopped.',
      );
    }
    final stopped = await adb.stopEmulator(serial);
    if (!stopped) {
      throw StateError(
        '$serial did not exit. It may be busy; try again, or close its window.',
      );
    }
    return {'serial': serial, 'stopped': true};
  }

  Future<Object?> _deviceTapElement({
    String? serial,
    required UiElementQuery query,
    int? index,
  }) async {
    if (query.isEmpty) {
      throw ArgumentError(
        'Give at least one of text, resourceId, contentDesc or className.',
      );
    }
    final device = await _resolveDevice(serial);
    final adb = _requireAdb();
    final tree = await adb.dumpUiHierarchy(device.serial);
    final screen = await adb.screenSize(device.serial);
    final matches = tree.find(query);

    if (matches.isEmpty) {
      throw StateError(
        'Nothing matches $query on ${device.serial}. On screen now:\n'
        '${renderUiElements(interestingNodes(tree), screen: screen, limit: 60).listing}',
      );
    }

    final UiNode target;
    if (index != null) {
      if (index < 0 || index >= matches.length) {
        throw ArgumentError(
          'index $index is out of range: there are ${matches.length} matches.',
        );
      }
      target = matches[index];
    } else if (matches.length == 1) {
      target = matches.first;
    } else {
      // Several matches. One unambiguous exact label is still a decision we can
      // make; anything else is a guess, and a wrong tap is worse than an error
      // because the agent cannot tell it happened.
      final exact = [
        for (final node in matches)
          if (query.rank(node) == 0) node,
      ];
      if (exact.length == 1) {
        target = exact.single;
      } else {
        throw StateError(
          '$query matches ${matches.length} elements on ${device.serial}. '
          'Pass index to choose, or narrow the query:\n'
          '${_indexed(matches, screen)}',
        );
      }
    }

    final bounds = target.tapBounds;
    if (bounds == null) {
      throw StateError(
        'The matched element reports no bounds, so there is nowhere to tap: '
        '${describeUiNode(target, screen: screen)}',
      );
    }
    if (screen != null && !bounds.centerIsOnScreen(screen)) {
      throw StateError(
        'The matched element is off screen at ${bounds.raw} on a $screen '
        'display — it is scrolled out of view. Scroll it into view first; '
        'tapping its centre would hit whatever is really at that point.',
      );
    }

    final point = bounds.center;
    await adb.tap(device.serial, point.x, point.y);
    return _uiText([
      'Tapped (${point.x}, ${point.y}) on '
          '${describeUiNode(target, screen: screen)}',
      'Device ${device.serial}, ${tree.packageName ?? 'unknown package'}'
          '${matches.length == 1 ? '' : ', chosen from ${matches.length} matches'}.'
          '${target.enabled ? '' : ' NOTE: this element is disabled.'}',
      'Take a screenshot or dump again to confirm what changed.',
    ]);
  }

  /// The matches numbered, so the caller can pass `index`.
  String _indexed(List<UiNode> matches, DeviceScreenSize? screen) => [
    for (var i = 0; i < matches.length && i < 20; i++)
      '[$i] ${describeUiNode(matches[i], screen: screen)}',
  ].join('\n');

  /// Wraps a listing as an MCP text block.
  ///
  /// Deliberately not returned as a JSON map: the bridge pretty-prints every
  /// map result, and one JSON object per node costs several times what one line
  /// per node does. The whole point of this surface is that a screen fits in a
  /// few hundred tokens.
  Object _uiText(List<String> sections) => {
    '_mcpContent': [
      {'type': 'text', 'text': sections.join('\n')},
    ],
  };

  LogLevel? _parseLogLevel(String? level) {
    if (level == null) return null;
    final needle = level.trim().toLowerCase();
    for (final value in LogLevel.values) {
      if (value.name == needle || value.code.toLowerCase() == needle) {
        return value;
      }
    }
    return null;
  }

  AgentInstallation? _installFor(String agentId, String? environmentId) {
    for (final install
        in _container.read(agentInstallationDaoProvider).getAll()) {
      if (install.agentId != agentId) continue;
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

  /// Both callers are resuming a conversation the agent already has, so both
  /// ask for the existing-session mode — through the launcher, which is the one
  /// place that turns a purpose into a [PermissionMode].
  PermissionMode _permissionFor(String agentId) => _container
      .read(sessionLauncherProvider)
      .permissionFor(agentId, SessionPurpose.existingSession);
}
