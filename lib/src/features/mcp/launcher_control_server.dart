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
import '../agents/domain/agent_ids.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../devices/application/device_providers.dart';
import '../devices/data/adb_service.dart';
import '../devices/domain/android_device.dart';
import '../devices/domain/device_input.dart';
import '../devices/domain/logcat_entry.dart';
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
      final settings = _container.read(settingsControllerProvider);
      install =
          resolveDefaultInstallation(
            installs,
            defaultInstallationId: settings.defaultAgentInstallationId,
            defaultAgentId: settings.defaultAgent,
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
      'opened': 'new ${install.agentId} session',
      'repository': repo.name,
      'environmentId': repo.path.environmentId,
    };
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

  PermissionMode _permissionFor(String agentId) => _container
      .read(settingsControllerProvider)
      .permissionsFor(agentId)
      .existingSessions;
}
