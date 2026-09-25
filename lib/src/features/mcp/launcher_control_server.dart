import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:riverpod/riverpod.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_core/logging.dart';
import '../../core/util/clock_provider.dart';
import '../automations/application/project_check_tools.dart';
import '../agents/application/agent_hook_intake.dart';
import '../agents/application/host_hook_endpoint.dart';
import 'package:agent_cli/descriptors.dart';
import '../browser/application/browser_consent_providers.dart';
import '../browser/application/browser_providers.dart';
import 'package:karmashala_browser/tools.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_reporting/hooks.dart' show kPaneSessionHeader;
import '../flutter_apps/application/flutter_app_tools.dart';
import '../app_projects/application/project_build_tools.dart';
import '../flutter_apps/application/flutter_run_tools.dart';
import '../checkpoints/application/checkpoint_turn_hints.dart';
import '../checkpoints/application/session_checkpoint_recorder.dart';
import '../verification/application/verification_providers.dart';
import '../verification/application/verification_tool_schemas.dart';
import '../verification/application/verification_tools.dart';
import 'attention_tools.dart';
import 'checkpoint_tools.dart';
import 'decision_tools.dart';
import 'review_thread_tools.dart';
import 'control_server_status.dart';
import 'device_tools.dart';
import 'fanout_tools.dart';
import 'package:karmashala_mcp/access.dart';
import 'package:karmashala_mcp/instructions.dart';
import 'inventory_tools.dart';
import 'project_tools.dart';
import 'package:karmashala_mcp/launch.dart';
import 'package:karmashala_mcp/protocol.dart';
import 'mcp_session_token_reaper.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'session_launch_tools.dart';
import 'session_mcp.dart';
import 'session_tools.dart';
import 'snippet_tools.dart';
import 'recording_tools.dart';
import 'terminal_tools.dart';
import 'tmux_tools.dart';
import 'todo_tools.dart';
import 'workspace_tools.dart';
import 'worktree_tools.dart';
import '../../core/paths/app_support_directory.dart';
import '../../core/probe/probe_mode.dart';

/// The port asked for before falling back to an ephemeral one. Fixed because a
/// Hyper-V firewall rule can name a port, never a program.
const int preferredControlPort = 47821;

/// How often to look again for the WSL switch while it is missing.
const Duration wslRetryInterval = Duration(seconds: 30);

/// A loopback HTTP server serving the MCP bridge (`POST /rpc`) and agents' own
/// hooks (`POST /agent-hook`). The tokens are the whole boundary.
class LauncherControlServer implements SessionMcp {
  LauncherControlServer(
    this._container, {
    AppLogger? logger,
    HandshakePermissions? permissions,
    File? Function()? bridgeExecutable,
    void Function(String path)? unpublish,
  }) : _logger = logger ?? AppLogger.named('mcp-control'),
       _permissions = permissions ?? const SystemHandshakePermissions(),
       _bridgeExecutable =
           bridgeExecutable ?? const LauncherMcp().bridgeExecutable,
       _unpublish = unpublish ?? _deleteIfPresent;

  final ProviderContainer _container;
  final AppLogger _logger;

  /// Resolves the stdio bridge shipped beside the app, or null. Injectable
  /// because that file's existence decides a WSL session's whole transport.
  final File? Function() _bridgeExecutable;

  /// How a published path is taken back off disk. Synchronous on purpose — see
  /// [stop] — and injectable so a test can count removals rather than time them.
  final void Function(String path) _unpublish;

  static void _deleteIfPresent(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Held by something, or already gone; a warning here would fire on
      // every clean quit.
    }
  }

  /// How the owner-only boundary is applied. Injectable because `icacls` cannot
  /// be made to fail on demand, and the fail-closed branch has to be testable.
  final HandshakePermissions _permissions;

  HttpServer? _server;

  /// A second listener on the WSL switch's host address, serving `/mcp` alone.
  /// Null with no such switch, and on runs where no MCP credential was minted.
  HttpServer? _wslServer;
  InternetAddress? _wslHost;

  /// Pending re-attempt at binding the WSL switch; also what keeps the log line
  /// above a one-off rather than a message every retry.
  Timer? _wslRetry;

  /// A field rather than [wslRetryInterval] itself, so a test can prove the
  /// retry without sleeping.
  Duration _wslRetryEvery = wslRetryInterval;

  /// Called the first time the switch binds *after* the initial attempt failed,
  /// so hooks skipped at startup can be installed now.
  void Function()? onWslInterfaceBound;
  LocalRpcServer? _socketServer;
  bool _httpRpcEnabled = false;
  String? _token;
  AgentHookEndpoint? _hookEndpoint;
  String? _publishedBridgePath;
  ControlServerStatus _status = ControlServerStatus.notStarted;
  McpHttpEndpoint? _mcpEndpoint;

  /// Where per-session MCP configs are written, or null when that directory
  /// could not be locked to this user and so nothing is written at all.
  SessionMcpConfigs? _sessionConfigs;

  /// Set by [stop] and read by [start] before each publish: a quit can land
  /// mid-start, and the rest of `start()` would otherwise publish behind it.
  bool _stopped = false;

  /// Which session each per-session MCP credential names. Survives the endpoint
  /// so a config written before a restart keeps meaning what it meant.
  final McpCallerRegistry _callers = McpCallerRegistry();

  /// Where a session's own MCP URL is built from, and what mints the token in
  /// it.
  McpCallerRegistry get callers => _callers;

  /// Retires those tokens when their sessions end. Started with the server and
  /// stopped with it, because a token only exists while the server does.
  late final McpSessionTokenReaper _tokenReaper = McpSessionTokenReaper(
    _container,
    _callers,
    logger: _logger,
  );

  /// One agent per request, however often it arrives: a worktree under `/mnt/c`
  /// outlives the 60s Claude Code waits, and its retry started a second agent.
  late final LaunchDedupe _launches = LaunchDedupe(
    clock: _container.read(clockProvider),
    onCollapsed: (tool) => _logger.warning(
      'A repeat $tool was collapsed onto the identical launch already made; '
      'nothing new was started. The caller most likely timed out and retried.',
    ),
  );

  /// The MCP endpoint URL for an unattributed caller, or null when nothing is
  /// served — the hardening failed, or the server is not started.
  String? get mcpUrl {
    final server = _server;
    final token = _mcpEndpoint?.token;
    if (server == null || token == null) return null;
    return 'http://127.0.0.1:${server.port}${McpHttpEndpoint.path}/$token';
  }

  /// The WSL virtual switch address this server also listens on, or null when
  /// it does not. Read by tests and by [mcpUrlFor]; nothing else needs it.
  InternetAddress? get wslHost => _wslHost;

  /// The MCP endpoint URL that says the caller **is** [sessionId] from
  /// [environment], or null — a WSL distro refuses loopback, SSH gets nothing.
  String? mcpUrlFor(String sessionId, {required EnvironmentKind environment}) {
    final host = _mcpHostFor(environment);
    if (host == null) return null;
    final token = _callers.tokenFor(sessionId);
    return 'http://$host${McpHttpEndpoint.path}/$token';
  }

  @override
  SessionMcpAccess? accessFor({
    required String sessionId,
    required ExecutionEnvironment environment,
    required bool withConfigFile,
  }) {
    final url = mcpUrlFor(sessionId, environment: environment.kind);
    // An agent whose convention is the URL itself has no file to read a
    // `command` out of.
    if (!withConfigFile) {
      return url == null ? null : SessionMcpAccess(url: url);
    }
    final entry = _serverEntryFor(environment.kind, url);
    if (entry == null) return null;
    final windowsPath = _sessionConfigs?.write(
      sessionId: sessionId,
      entry: entry,
    );
    if (windowsPath == null) return null;
    final agentPath = agentConfigPathFor(windowsPath, environment.kind);
    // A file the agent cannot name is a flag pointing at nothing, which is a
    // worse launch than the one that passes no flag at all.
    if (agentPath == null) return null;
    // Reported only when the file actually names one: a config that spawns the
    // bridge is not dialling anything, so its URL would point at nothing.
    final describesUrl = entry['url'] != null;
    return SessionMcpAccess(
      url: describesUrl ? url : null,
      configPath: agentPath,
    );
  }

  /// The `mcpServers.karmashala` entry for an agent in [environment], or `null`.
  /// Only [EnvironmentKind.wsl] differs: it is given the stdio bridge.
  Map<String, Object?>? _serverEntryFor(
    EnvironmentKind environment,
    String? url,
  ) {
    if (environment == EnvironmentKind.wsl) {
      final bridge = _bridgeExecutable()?.path;
      // Spelled the way the agent names it. `null` is a UNC install directory,
      // which has no `/mnt/` form.
      final agentPath = bridge == null
          ? null
          : agentConfigPathFor(bridge, environment);
      if (agentPath != null) return LauncherMcp.commandServerEntry(agentPath);
    }
    return url == null ? null : LauncherMcp.httpServerEntry(url);
  }

  /// `host:port` for an agent in [environment], or null when there is none.
  String? _mcpHostFor(EnvironmentKind environment) {
    final server = _server;
    if (server == null || _mcpEndpoint?.token == null) return null;
    return switch (environment) {
      EnvironmentKind.windowsNative ||
      EnvironmentKind.localPosix => '127.0.0.1:${server.port}',
      EnvironmentKind.wsl =>
        _wslHost == null ? null : '${_wslHost!.address}:${server.port}',
      EnvironmentKind.ssh => null,
    };
  }

  /// What came up, and what did not. Mirrored into
  /// [controlServerStatusProvider] so the settings screen can say so.
  ControlServerStatus get status => _status;

  /// Shared with the hook scripts that produce the payloads, so the two ends
  /// of the wire cannot come to disagree about what is too big.
  static const _maxRequestBytes = kAgentHookPayloadLimitBytes;

  /// What `serverInfo` reports. Not the app's version: this is the version of
  /// the *tool surface*, and it moves when the tools do.
  static const String _serverVersion = '2.0.0';

  /// The one paragraph a model reads before it has called anything.
  static const String _instructions =
      'These tools drive Karmashala itself — the sessions, terminal tabs, '
      'projects, notes, inbox and delivery state of the app this agent is '
      'running inside. Tools that name a session default to the session '
      'calling them, so omit sessionId to act on yourself. Anything Karmashala '
      'has not measured is reported as "not recorded" rather than guessed.';

  /// Where agents' installed hooks post to, once [start] has bound the port;
  /// `null` before that, and when the session host takes them instead.
  AgentHookEndpoint? get hookEndpoint => _hookEndpoint;

  /// Where the bridge reads the port + token from.
  static Future<String> bridgeFilePath() async {
    final dir = await appSupportDirectory();
    return p.join(dir.path, 'mcp_bridge.json');
  }

  /// Binds the server and writes the handshake file. Fails closed: if an ACL or
  /// the socket bind does not apply, no privileged token is minted or published.
  Future<void> start({
    String? bridgeFilePath,
    bool useLocalSocket = true,
    String? socketDirectory,
    String? sessionConfigDirectory,
    Future<InternetAddress?> Function() wslHostAddress = resolveWslHostAddress,
    bool? hostCanHaveWsl,
    int preferredPort = preferredControlPort,
    Duration retryWslEvery = wslRetryInterval,
  }) async {
    if (_server != null) return;
    _stopped = false;
    _wslRetryEvery = retryWslEvery;
    // A probe takes an ephemeral port: holding the preferred one would push the
    // real app off it when it next starts.
    final server = await _bindControlPort(
      _container.read(probeModeProvider).enabled ? 0 : preferredPort,
    );
    _server = server;
    if (await _abandonedMidStart()) return;
    // A *separate* token for /agent-hook: it is pasted verbatim into a curl
    // command in the agent's own config, so it shows up in command lines too.
    // None when the session host takes hooks: the route then answers nobody.
    _hookEndpoint = _container.read(agentHooksAtHostProvider)
        ? null
        : AgentHookEndpoint(port: server.port, token: _generateToken());
    _mcpEndpoint = McpHttpEndpoint(
      server: McpServer(
        name: 'karmashala',
        version: _serverVersion,
        // Read on every `tools/list` rather than captured, because the browser
        // and verification tools come from services that may not be up yet.
        catalogue: () => annotatedToolSchemas(toolSchemas),
        invoke: (name, arguments, callerSessionId) =>
            _dispatch(name, arguments, callerSessionId),
        instructions: _instructions,
      ),
      callers: _callers,
      logger: _logger,
    );

    ControlServerFailureStage? stage;
    String? detail;

    if (useLocalSocket) {
      try {
        _socketServer = await _bindLocalSocket(socketDirectory);
      } on _HardeningFailure catch (failure) {
        stage = failure.stage;
        detail = failure.detail;
      } on Object catch (error, stack) {
        stage = ControlServerFailureStage.socketBind;
        detail = '$error';
        _logger.warning('Owner-only RPC socket failed to bind.', error, stack);
      }
    } else {
      // The deliberate opt-out: a caller has asked for loopback HTTP in code.
      _httpRpcEnabled = true;
    }

    // A privileged credential is minted only where a privileged transport came
    // up: an unpublishable secret on disk is pure downside.
    if (_socketServer != null || _httpRpcEnabled) {
      _token = _generateToken();
      // `/mcp` is gated on the same prerequisite: serving it when the
      // owner-only channel failed is the silent downgrade to avoid.
      _mcpEndpoint!.token = _generateToken();
    }

    // Restrict the (still empty) file before deciding what goes in it, so a
    // token is never written under an ACL that was not applied.
    final file = await _prepareBridgeFile(bridgeFilePath);
    var restricted = false;
    try {
      restricted = await _permissions.restrictFile(file, logger: _logger);
    } on Object catch (error, stack) {
      // A throw and a `false` mean the same thing here: the ACL is not on.
      detail ??= '$error';
      _logger.warning('Handshake file could not be restricted.', error, stack);
    }
    if (!restricted && _token != null) {
      // The handshake is the only way the token reaches the bridge; if it
      // cannot be locked to this account, the token and the transport both go.
      stage ??= ControlServerFailureStage.handshakePermissions;
      detail ??= 'the handshake file ACL was not applied';
      await _withholdPrivilegedRpc();
    }
    if (await _abandonedMidStart()) return;
    await _publishHandshake(file, server.port);
    if (await _abandonedMidStart()) return;

    _publishStatus(
      stage == null
          ? ControlServerStatus.running(
              _socketServer != null
                  ? PrivilegedRpcTransport.ownerOnlySocket
                  : PrivilegedRpcTransport.loopbackHttp,
            )
          : ControlServerStatus.failedClosed(stage: stage, detail: detail!),
    );

    server.listen(_handle, onError: (Object e) => _logger.warning('$e'));
    _logger.info('Launcher control server on 127.0.0.1:${server.port}.');
    if (hostCanHaveWsl ?? Platform.isWindows) {
      await _bindWslInterface(server.port, wslHostAddress);
    }
    // The last checkpoint: looking for the WSL switch is a subprocess and a
    // bind, and the directory below is created after it.
    if (await _abandonedMidStart()) return;
    // Beside the handshake file: a second `appSupportDirectory()` would be a
    // platform-channel call for a path every caller has already given us.
    await _prepareSessionConfigs(
      sessionConfigDirectory ?? p.join(p.dirname(file.path), 'mcp'),
    );
    if (await _abandonedMidStart()) return;
    _publishSessionMcp(this);
    _startCheckpointRecorder();
    _tokenReaper.start();
  }

  /// Whether a [stop] landed while [start] was suspended — and if it did,
  /// unwinds through [stop] again, which is idempotent by construction.
  Future<bool> _abandonedMidStart() async {
    if (!_stopped) return false;
    _logger.info('Control server start abandoned: the app is quitting.');
    await stop();
    return true;
  }

  /// Binds the control port, preferring [preferredControlPort]. Falling back
  /// costs only reachability from WSL, so it is logged rather than left silent.
  Future<HttpServer> _bindControlPort(int preferred) async {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, preferred);
    } on SocketException catch (error) {
      _logger.info(
        controlPortFallbackMessage(
          preferred,
          error,
          hostIsWindows: Platform.isWindows,
        ),
      );
      return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
  }

  /// Also listens on the WSL switch's host address, so an agent inside a
  /// distribution can dial `/mcp` at all. Never fatal.
  Future<void> _bindWslInterface(
    int port,
    Future<InternetAddress?> Function() lookup,
  ) async {
    try {
      final host = await lookup();
      if (host == null) {
        // Giving up silently here disabled WSL tools and hooks for a whole
        // run: an app that starts with Windows starts before WSL does.
        if (_wslRetry == null) {
          _logger.info(
            'No WSL switch adapter yet (looking for one named '
            '"vEthernet (WSL...)"), so WSL sessions have no tools and no '
            'hooks for now. Retrying every '
            '${_wslRetryEvery.inSeconds}s.',
          );
        }
        _scheduleWslRetry(port, lookup);
        return;
      }
      final server = await HttpServer.bind(host, port);
      _wslServer = server;
      _wslHost = host;
      // [_hookEndpoint] is deliberately not republished: this listener completes
      // the handshake and then resets every byte, so those hooks use the spool.
      server.listen(
        _handleWslInterface,
        onError: (Object e) => _logger.warning('$e'),
      );
      _logger.info('MCP also on ${host.address}:$port, for WSL sessions.');
      final wasRetrying = _wslRetry != null;
      _cancelWslRetry();
      // A distribution that appears late is one whose stores the first install
      // sweep could not find either.
      if (wasRetrying) onWslInterfaceBound?.call();
    } on Object catch (error, stack) {
      _logger.warning(
        'MCP could not listen on the WSL interface; '
        'sessions in WSL will launch without it.',
        error,
        stack,
      );
      _scheduleWslRetry(port, lookup);
    }
  }

  /// Looks for the switch again later. The adapter appears when WSL first
  /// starts, which is routinely long after an app that launches with Windows.
  void _scheduleWslRetry(int port, Future<InternetAddress?> Function() lookup) {
    _wslRetry?.cancel();
    _wslRetry = Timer(_wslRetryEvery, () {
      // The server was stopped while we waited; nothing to bind to any more.
      if (_server == null) return;
      unawaited(_bindWslInterface(port, lookup));
    });
  }

  void _cancelWslRetry() {
    _wslRetry?.cancel();
    _wslRetry = null;
  }

  /// Creates the owner-only directory per-session MCP configs go in, empty, and
  /// only where a credential exists — a config for a `401` is a leaked secret.
  Future<void> _prepareSessionConfigs(String dirPath) async {
    if (_mcpEndpoint?.token == null) return;
    _sessionConfigs = await SessionMcpConfigs.prepare(
      Directory(dirPath),
      (dir) => _permissions.restrictDirectory(dir, logger: _logger),
    );
    if (_sessionConfigs == null) {
      // Not fatal: an agent that takes the URL on its command line is
      // unaffected, and one that needs a file launches without it.
      _logger.warning(
        'MCP session configs are off: $dirPath could not be locked to this '
        'user. Agents that need a config file will launch without one.',
      );
    }
  }

  /// Publishes (or withdraws) the wiring a launch reads.
  void _publishSessionMcp(SessionMcp? value) {
    try {
      _container.read(sessionMcpProvider.notifier).adopt(value);
    } on Object catch (error) {
      // A disposed container on the way out, exactly as in _publishStatus.
      _logger.warning('Could not publish the session MCP wiring: $error');
    }
  }

  /// Takes down whatever privileged RPC had come up and destroys its
  /// credential. Idempotent; `/agent-hook` is untouched.
  Future<void> _withholdPrivilegedRpc() async {
    try {
      await _socketServer?.close();
    } on Object catch (error) {
      _logger.warning('Could not close the owner-only RPC socket: $error');
    }
    _socketServer = null;
    _token = null;
    _httpRpcEnabled = false;
    _mcpEndpoint?.token = null;
  }

  void _publishStatus(ControlServerStatus status) {
    _status = status;
    if (status.failedClosed) {
      _logger.error(
        'control-server: privileged RPC withheld '
        'stage=${status.failureStage!.name} reason=${status.failureDetail}',
      );
    }
    try {
      _container.read(controlServerStatusProvider.notifier).set(status);
    } on Object catch (error) {
      // A disposed container on the way out must not turn into a start/stop
      // failure; the log line above is the record that matters.
      _logger.warning('Could not publish control server status: $error');
    }
  }

  /// Brings the per-turn checkpoint recorder to life. It subscribes to the
  /// status registry itself: a Riverpod `listen` inside an unwatched provider
  /// is paused, which is how every turn but a visible pane's went unrecorded.
  void _startCheckpointRecorder() {
    try {
      _container.read(sessionCheckpointRecorderProvider.notifier).start();
    } on Object catch (error, stack) {
      _logger.warning('Checkpoint recorder failed to start.', error, stack);
    }
  }

  /// Creates the owner-only directory and binds the RPC socket inside it: a unix
  /// socket carries no permissions, so the directory ACL is the whole boundary.
  Future<LocalRpcServer> _bindLocalSocket(String? overrideDirectory) async {
    final dirPath =
        overrideDirectory ?? p.join((await appSupportDirectory()).path, 'ipc');
    final dir = Directory(dirPath);
    await dir.create(recursive: true);
    if (!await _permissions.restrictDirectory(dir, logger: _logger)) {
      throw _HardeningFailure(
        ControlServerFailureStage.socketDirectoryPermissions,
        'the owner-only ACL on $dirPath was not applied',
      );
    }
    final socketPath = switch (locateSocket(p.join(dir.path, 'rpc.sock'))) {
      PreferredSocketLocation(:final path) => path,
      // Too long to bind where it was put — a data directory deep in a repo,
      // a long or non-Latin username. Without this the bind failed and every
      // privileged tool was withheld from the agents in this instance.
      final FallbackSocketLocation location => await _prepareFallback(location),
      UnplaceableSocket(:final reason) => throw _HardeningFailure(
        ControlServerFailureStage.socketBind,
        reason,
      ),
    };
    final socket = await LocalRpcServer.bind(socketPath, _handleSocketRpc);
    _logger.info('Owner-only RPC socket at $socketPath.');
    return socket;
  }

  /// Makes [location]'s directory as private as `ipc/` itself — proven private
  /// by the IPC package, then given the same owner-only ACL — and returns the
  /// path to bind. Clients find it in the handshake, so nothing else changes.
  Future<String> _prepareFallback(FallbackSocketLocation location) async {
    final refused = await prepareFallbackSocketDirectory(location);
    if (refused != null) {
      throw _HardeningFailure(
        ControlServerFailureStage.socketDirectoryPermissions,
        refused,
      );
    }
    final fallback = Directory(location.directory);
    if (!await _permissions.restrictDirectory(fallback, logger: _logger)) {
      throw _HardeningFailure(
        ControlServerFailureStage.socketDirectoryPermissions,
        'the owner-only ACL on ${location.directory} was not applied',
      );
    }
    _logger.info('RPC socket moved: ${location.reason}.');
    return location.path;
  }

  /// Stops the server, removing the published files **first and synchronously**:
  /// the lifecycle bounds the wait, not the work, and its slice is 100 ms.
  Future<void> stop() async {
    // A `start()` suspended above reads this at its next checkpoint.
    _stopped = true;
    _cancelWslRetry();
    _tokenReaper.stop();
    if (_publishedBridgePath case final published?) _unpublish(published);
    // The socket node too: unlinking a *bound* one is immediate, so
    // `LocalRpcServer.close` finds nothing left to delete after its own await.
    if (_socketServer case final socket?) _unpublish(socket.path);
    // And the per-session MCP configs, which are a whole directory tree.
    _sessionConfigs?.dispose();
    _sessionConfigs = null;

    // Sockets only from here down: slow, and touching nothing on disk, so a
    // step abandoned on its budget leaves nothing observable running.
    await _server?.close(force: true);
    await _wslServer?.close(force: true);
    await _socketServer?.close();
    _publishSessionMcp(null);
    _server = null;
    _wslServer = null;
    _wslHost = null;
    _socketServer = null;
    _token = null;
    _hookEndpoint = null;
    _httpRpcEnabled = false;
    _mcpEndpoint = null;
    _callers.clear();
    _publishedBridgePath = null;
    _publishStatus(ControlServerStatus.notStarted);
  }

  /// Creates the handshake file **empty**, ready to be restricted. A pre-existing
  /// one is removed, not overwritten: a write preserves the DACL it carries.
  Future<File> _prepareBridgeFile(String? overridePath) async {
    final file = File(overridePath ?? await bridgeFilePath());
    _publishedBridgePath = file.path;
    await file.parent.create(recursive: true);
    try {
      if (file.existsSync()) await file.delete();
    } catch (error) {
      // A bridge still holding it open; the restriction covers us.
      _logger.warning('Could not replace the handshake file: $error');
    }
    await file.create();
    return file;
  }

  /// Publishes the port, the pid and whichever credentials survived hardening:
  /// `token` and `socketPath` only when a privileged transport is up.
  Future<void> _publishHandshake(File file, int port) async {
    await file.writeAsString(
      jsonEncode({
        'port': port,
        'pid': pid,
        'hookToken': ?_hookEndpoint?.token,
        'token': ?_token,
        if (_socketServer case final socket?) 'socketPath': socket.path,
        // Present only when a credential for it actually exists.
        'mcpToken': ?_mcpEndpoint?.token,
        if (_mcpEndpoint?.token != null)
          'mcpUrl': 'http://127.0.0.1:$port${McpHttpEndpoint.path}',
      }),
      flush: true,
    );
  }

  /// 24 bytes from the platform CSPRNG, base64url-encoded. [Random.secure] and
  /// not [Random]: these tokens are the entire access-control boundary.
  String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// The WSL listener's whole routing table: the two routes an agent inside a
  /// distribution has to reach, and `404` for the rest.
  Future<void> _handleWslInterface(HttpRequest request) async {
    if (request.uri.path == '/agent-hook') {
      await _handleAgentHook(request);
      return;
    }
    if (McpHttpEndpoint.handles(request.uri)) {
      await _mcpEndpoint!.handle(request);
      return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/agent-hook') {
      await _handleAgentHook(request);
      return;
    }
    // MCP authenticates itself, with a different credential and a different
    // rule about who the caller is, so it is routed before the bearer check.
    if (McpHttpEndpoint.handles(request.uri)) {
      await _mcpEndpoint!.handle(request);
      return;
    }
    final response = request.response;
    try {
      final token = _token;
      // No privileged credential means no privileged caller. Without this an
      // interpolated `Bearer null` would be a header anyone could send.
      if (token == null ||
          !_constantTimeEquals(
            request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer $token',
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
      // Which of *our* sessions is calling: read from the environment Karmashala
      // stamped on the process, not from the model.
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

  /// One `/rpc` call over the owner-only socket. The directory ACL is the
  /// boundary; the token is a second lock behind it.
  Future<String> _handleSocketRpc(String body) async {
    try {
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final token = _token;
      if (token == null ||
          !_constantTimeEquals(payload['token'] as String?, token)) {
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
      // The same three steps a spooled payload goes through, so the two
      // transports cannot disagree about what "a hook arrived" means.
      final report = applyAgentHookCallback(
        _container,
        agentId: request.uri.queryParameters['agent'],
        event: request.uri.queryParameters['event'],
        body: body,
        paneSessionId: request.headers.value(kPaneSessionHeader),
        logger: _logger,
      );
      // The one bounded hold: a tool about to write waits, at most
      // kCheckpointHookHold, for the checkpoint that can undo it.
      try {
        await holdToolForCheckpoint(
          _container,
          agentSessionId: report.sessionId,
          event: request.uri.queryParameters['event'],
        );
      } on Object catch (error) {
        _logger.warning('Holding a tool for its checkpoint failed: $error');
      }
      // Always 200 on an authenticated callback, even for an event we do not
      // recognise: a hook must never fail the agent that fired it.
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

  bool _constantTimeEquals(String? actual, String expected) =>
      constantTimeEquals(actual, expected);

  /// One RPC, guarded against being made twice. Only the tools that *start*
  /// something go through the ledger; a read must not be collapsed.
  Future<Object?> _dispatch(
    String? tool,
    Map<String, dynamic> args, [
    String? callerSessionId,
  ]) {
    if (tool != null && startsAnAgent(tool, args)) {
      return _launches.run(
        tool: tool,
        arguments: args,
        callerSessionId: callerSessionId,
        start: () => _invoke(tool, args, callerSessionId),
      );
    }
    return _invoke(tool, args, callerSessionId);
  }

  Future<Object?> _invoke(
    String? tool,
    Map<String, dynamic> args, [
    String? callerSessionId,
  ]) async {
    switch (tool) {
      case '__list_tools__':
        return toolSchemas;
      case final String name when InventoryTools.handles(name):
        return InventoryTools(_container).call(name, args);
      case final String name when ProjectControlTools.handles(name):
        return ProjectControlTools(_container).call(name, args);
      // The caller's identity matters: a session started here is recorded as
      // its child, which is what the spawn-depth cap counts.
      case final String name when SessionLaunchTools.handles(name):
        return SessionLaunchTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when FanOutTools.handles(name):
        return FanOutTools(_container).call(name, args);
      case final String name when TmuxControlTools.handles(name):
        return TmuxControlTools(_container).call(name, args);
      case final String name when CheckpointControlTools.handles(name):
        return CheckpointControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when SessionControlTools.handles(name):
        return SessionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when AttentionControlTools.handles(name):
        return AttentionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when TodoControlTools.handles(name):
        return TodoControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when DecisionControlTools.handles(name):
        return DecisionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when ReviewThreadTools.handles(name):
        return ReviewThreadTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when WorkspaceControlTools.handles(name):
        return WorkspaceControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when WorktreeControlTools.handles(name):
        return WorktreeControlTools(_container).call(name, args);
      case final String name when DeviceControlTools.handles(name):
        return DeviceControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when TerminalControlTools.handles(name):
        return TerminalControlTools(_container).call(name, args);
      case final String name when RecordingControlTools.handles(name):
        return RecordingControlTools(_container).call(name, args);
      case final String name when SnippetControlTools.handles(name):
        return SnippetControlTools(_container).call(name, args);
      case final String name when InstructionsTools.handles(name):
        return const InstructionsTools().call(name, args);
      // Consent is resolved here, not in features/browser: which project a call
      // is for is a sessions question, and nothing about it is cached.
      case final String name when BrowserTools.handles(name):
        return BrowserTools(
          _container.read(browserServiceProvider),
          consent: browserConsentFor(
            _container,
            callerSessionId: callerSessionId,
          ),
        ).call(name, args);
      case final String name when FlutterAppTools.handles(name):
        return FlutterAppTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when FlutterRunTools.handles(name):
        return FlutterRunTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when ProjectBuildTools.handles(name):
        return ProjectBuildTools(_container).call(name, args);
      case final String name when ProjectCheckTools.handles(name):
        return ProjectCheckTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      case final String name when VerificationTools.handles(name):
        await resolveVerificationRoot();
        final verification = _container.read(verificationServiceProvider);
        // Noted *before* the call, because finishing clears the active run: the
        // seam where verification writes to the decision record.
        final finishing = name == 'verification_finish'
            ? verification.activeRun?.id
            : null;
        // The caller is the producer of every verdict recorded here (G3).
        final answer = await VerificationTools(
          verification,
          callerSessionId: callerSessionId,
        ).call(name, args);
        if (finishing != null) {
          recordFinishedVerdict(_container, verification.get(finishing));
        }
        return answer;
      default:
        throw ArgumentError('Unknown tool: $tool');
    }
  }

  /// MCP tool definitions (name/description/inputSchema) served to the bridge.
  static const List<Map<String, dynamic>> toolSchemas = [
    ...checkpointControlToolSchemas,
    ...inventoryToolSchemas,
    ...projectControlToolSchemas,
    ...projectCheckToolSchemas,
    ...sessionLaunchToolSchemas,
    ...fanOutToolSchemas,
    ...sessionHandoffToolSchemas,
    ...tmuxToolSchemas,
    ...instructionsToolSchemas,
    ...sessionControlToolSchemas,
    ...terminalControlToolSchemas,
    ...recordingControlToolSchemas,
    ...snippetControlToolSchemas,
    ...workspaceControlToolSchemas,
    ...worktreeControlToolSchemas,
    ...deviceControlToolSchemas,
    ...attentionControlToolSchemas,
    ...todoControlToolSchemas,
    ...decisionControlToolSchemas,
    ...reviewThreadToolSchemas,
    ...browserToolSchemas,
    ...flutterAppToolSchemas,
    ...flutterRunToolSchemas,
    ...projectBuildToolSchemas,
    ...verificationToolSchemas,
  ];
}

/// A hardening step that did not apply, thrown out of the privileged-transport
/// setup so `start` can fail closed with the reason intact.
class _HardeningFailure implements Exception {
  _HardeningFailure(this.stage, this.detail);

  final ControlServerFailureStage stage;
  final String detail;

  @override
  String toString() => detail;
}

/// What to log when the fixed control port is taken. [hostIsWindows] because
/// what is lost is WSL's reachability, which cannot exist on a Mac.
String controlPortFallbackMessage(
  int port,
  Object error, {
  required bool hostIsWindows,
}) =>
    'Port $port is taken, so this run uses an ephemeral one.'
    '${hostIsWindows ? ' Agents inside WSL will not be able to reach this '
              'server: the Hyper-V firewall rule the installer wrote names that '
              'one port.' : ''}'
    ' ($error)';
