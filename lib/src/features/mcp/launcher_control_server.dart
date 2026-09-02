import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_local_ipc/karmashala_local_ipc.dart';
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
import '../browser/application/browser_consent_providers.dart';
import '../browser/application/browser_providers.dart';
import '../browser/application/browser_tool_schemas.dart';
import '../browser/application/browser_tools.dart';
import '../cli_detection/application/cli_detection_providers.dart';
import '../environments/application/environment_providers.dart';
import '../fanout/application/comparison_providers.dart';
import '../environments/domain/environment_kind.dart';
import '../environments/domain/environment_path.dart';
import '../environments/domain/execution_environment.dart';
import '../notifications/application/notification_providers.dart';
import '../projects/application/projects_controller.dart';
import '../repositories/application/repository_providers.dart';
import '../repositories/domain/repository.dart';
import '../sessions/application/session_handoff_service.dart';
import '../sessions/application/session_launcher.dart';
import '../checkpoints/application/session_checkpoint_recorder.dart';
import '../sessions/application/session_providers.dart';
import '../sessions/domain/session.dart';
import '../sessions/domain/session_launch.dart';
import '../sessions/domain/session_lineage.dart';
import '../settings/domain/permission_mode.dart';
import '../terminal/application/system_terminal_providers.dart';
import '../terminal/data/system_terminal_service.dart';
import '../verification/application/verification_providers.dart';
import '../verification/application/verification_tool_schemas.dart';
import '../verification/application/verification_tools.dart';
import 'attention_tools.dart';
import 'checkpoint_tools.dart';
import 'decision_tools.dart';
import 'review_thread_tools.dart';
import 'control_server_status.dart';
import 'device_tools.dart';
import 'handshake_file_permissions.dart';
import 'instructions_tools.dart';
import 'mcp_caller_registry.dart';
import 'mcp_http_endpoint.dart';
import 'mcp_protocol.dart';
import 'mcp_session_token_reaper.dart';
import 'mcp_tool_catalogue.dart';
import 'session_mcp.dart';
import 'session_tools.dart';
import 'terminal_tools.dart';
import 'tmux_orchestration.dart';
import 'workspace_tools.dart';
import 'worktree_tools.dart';
import 'wsl_host_address.dart';

/// The port the control server asks for before falling back to an ephemeral one.
///
/// WSL2 reaches the host over a Hyper-V virtual switch, and that traffic is
/// governed by a **separate** firewall from the ordinary one — on this machine
/// `Get-NetFirewallHyperVVMSetting` reports `DefaultInboundAction: Block`. An
/// agent in a distribution therefore cannot reach this server at all unless a
/// Hyper-V rule names it, which is why hooks failed on every prompt with
/// `curl: (52) Empty reply from server` while the very same request from
/// Windows got a clean `401`: nothing was wrong with the server, and no
/// ordinary firewall rule could have helped.
///
/// Those rules are scoped to **ports, never to programs**, so an ephemeral
/// port cannot be allowed: it moves every launch and the installer has no way
/// to name it in advance. Hence one stable port, chosen below Windows'
/// ephemeral range (49152+) so it is unlikely to be taken, and written into
/// the installer's rule.
const int preferredControlPort = 47821;

/// How often to look again for the WSL switch while it is missing.
/// Cheap — one interface enumeration — and it stops at the first success.
const Duration wslRetryInterval = Duration(seconds: 30);

/// A loopback HTTP server that exposes karmashala's data and actions to the
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
/// **Every step of that hardening is a prerequisite, not a best effort.** The
/// directory ACL, the socket bind and the handshake file's ACL each have to
/// succeed before a privileged token exists at all; if any of them does not,
/// nothing privileged is bound, no privileged credential is minted or
/// published, and [ControlServerStatus] says why. Loop 61 wrote that down after
/// an audit found the ACL results were being read and then ignored: the
/// promise was in this comment and nowhere in the code, because no test could
/// reach the branch. See `start`.
///
/// This replaced a Windows-only named pipe. The pipe's DACL gave the same
/// boundary, but it left Linux and macOS on loopback TCP, and its blocking-FFI
/// serving isolate could not be shut down: Loop 48 measured a build with the
/// pipe running failing to exit at all on quit (>120 s), against 322 ms for the
/// same build without it.
///
/// Agent hooks remain on HTTP, deliberately. The hook command is
/// `curl -sS -m 2 -X POST … /agent-hook`, written into third-party agents' own
/// config files and run by whatever `curl` those agents find — including agents
/// running in WSL or over SSH, for which a Windows socket path is not a
/// reachable name at all. Their token is separate and low-privilege (status
/// reports only), and is already public to anything that can list process
/// command lines; that is the threat model above, and moving the route would
/// not improve it.
///
/// The route answers on **both** doors: loopback for a Windows-native agent,
/// and the WSL switch address for one inside a distribution, which cannot dial
/// loopback at all. See [_bindWslInterface].
class LauncherControlServer implements SessionMcp {
  LauncherControlServer(
    this._container, {
    AppLogger? logger,
    HandshakePermissions? permissions,
  }) : _logger = logger ?? AppLogger.named('mcp-control'),
       _permissions = permissions ?? const SystemHandshakePermissions();

  final ProviderContainer _container;
  final AppLogger _logger;

  /// How the owner-only boundary is applied. Injectable because the failure
  /// path *is* the security contract: `icacls` cannot be made to fail on
  /// demand, so without a seam the fail-closed branch below is untestable — and
  /// it was, which is how it came to be ignored in the first place.
  final HandshakePermissions _permissions;

  HttpServer? _server;

  /// A second listener on the WSL virtual switch's host address, serving
  /// `/mcp` and nothing else. Null on a machine with no such switch, and on
  /// every run where no MCP credential was minted. See [_bindWslInterface].
  HttpServer? _wslServer;
  InternetAddress? _wslHost;

  /// Pending re-attempt at binding the WSL switch, or null when there is none
  /// outstanding — which is also how the log line above stays a one-off rather
  /// than a message every retry.
  Timer? _wslRetry;

  /// How long to wait before looking for the switch again. A field rather than
  /// the constant directly so a test can prove the retry without sleeping.
  Duration _wslRetryEvery = wslRetryInterval;

  /// Called the first time the switch is bound *after* the initial attempt
  /// failed, so hooks skipped at startup can be installed now that a WSL agent
  /// has an address to post to.
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

  /// The MCP endpoint URL that says the caller **is** [sessionId], written for
  /// an agent running in [environment] — or null when no address this server
  /// listens on can be reached from there.
  ///
  /// This is the whole identity mechanism on the HTTP side: the app mints an
  /// opaque token for one session, writes this URL into that session's MCP
  /// config, and the endpoint maps the token back. The agent never has to be
  /// told its own id and cannot claim a different one, which is the same
  /// property `KARMASHALA_SESSION_ID` gives the stdio bridge — the app stamps
  /// identity on the process, the model does not declare it.
  ///
  /// **The environment is required, and the answer genuinely differs.** A WSL2
  /// distribution has its own network namespace, so the loopback URL that is
  /// right for a Windows-native pane is refused from inside one — see
  /// [wslHostAddressAmong] for the measurement. An agent over SSH is on another
  /// machine entirely and gets nothing, because the only way to reach it would
  /// be to bind an interface the network can see, and the token in this URL
  /// opens the app's whole tool surface.
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
    if (url == null) return null;
    if (!withConfigFile) return SessionMcpAccess(url: url);
    final windowsPath = _sessionConfigs?.write(
      sessionId: sessionId,
      url: url,
    );
    if (windowsPath == null) return null;
    final agentPath = agentConfigPathFor(windowsPath, environment.kind);
    // A file the agent cannot name is a flag pointing at nothing, which is a
    // worse launch than the one that passes no flag at all.
    if (agentPath == null) return null;
    return SessionMcpAccess(url: url, configPath: agentPath);
  }

  /// `host:port` for an agent in [environment], or null when there is none.
  String? _mcpHostFor(EnvironmentKind environment) {
    final server = _server;
    if (server == null || _mcpEndpoint?.token == null) return null;
    return switch (environment) {
      EnvironmentKind.windowsNative ||
      EnvironmentKind.localPosix => '127.0.0.1:${server.port}',
      EnvironmentKind.wsl => _wslHost == null
          ? null
          : '${_wslHost!.address}:${server.port}',
      EnvironmentKind.ssh => null,
    };
  }

  /// What came up, and what did not. Mirrored into
  /// [controlServerStatusProvider] so the settings screen can say so.
  ControlServerStatus get status => _status;

  static const _maxRequestBytes = 1024 * 1024;

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
  ///
  /// [wslHostAddress] is where the second `/mcp` listener goes. It defaults to
  /// the real machine's WSL switch; tests inject a stand-in so two-interface
  /// behaviour is provable on a host that has no WSL at all.
  ///
  /// [hostCanHaveWsl] gates that second listener on the host being able to run
  /// WSL at all. Off Windows there is no switch to wait for, so looking is not
  /// a temporary miss to be retried but a permanent no — without this a macOS
  /// or Linux launch logged a Windows-shaped warning and then re-ran the
  /// interface scan every 30 seconds, for the life of the process, to
  /// rediscover that it is not Windows. Tests that exercise the WSL path pass
  /// `true` alongside their stand-in [wslHostAddress].
  ///
  /// [sessionConfigDirectory] is where per-session MCP configs are written; by
  /// default `mcp` beside the handshake file, which puts it in the
  /// application-support directory in the app and in the test's temp directory
  /// in a test.
  ///
  /// ## Fail closed
  ///
  /// Every privileged step is a **prerequisite**, not a best effort. Applying
  /// the owner-only ACL to the socket directory, binding the socket inside it,
  /// and applying the owner-only ACL to the handshake file all have to succeed
  /// before a privileged token is minted and published. If any of them does
  /// not, this method still returns — the deliberately low-privilege
  /// `/agent-hook` route stays up, because an agent that cannot report status
  /// is a worse outcome than one that cannot drive a device — but no privileged
  /// transport is listening and no privileged credential exists to be leaked.
  /// The reason goes to the log and to [controlServerStatusProvider].
  Future<void> start({
    String? bridgeFilePath,
    bool useLocalSocket = true,
    String? socketDirectory,
    String? sessionConfigDirectory,
    Future<InternetAddress?> Function() wslHostAddress =
        resolveWslHostAddress,
    bool? hostCanHaveWsl,
    int preferredPort = preferredControlPort,
    Duration retryWslEvery = wslRetryInterval,
  }) async {
    if (_server != null) return;
    _wslRetryEvery = retryWslEvery;
    final server = await _bindControlPort(preferredPort);
    _server = server;
    // A *separate* token for /agent-hook. It is pasted verbatim into a curl
    // command in the agent's own config file, so it also shows up in process
    // command lines; the /rpc token opens sessions and drives devices, and must
    // not be exposed that widely.
    _hookEndpoint = AgentHookEndpoint(
      port: server.port,
      token: _generateToken(),
    );
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
        // The stack, here; the structured one-liner comes from _publishStatus.
        _logger.warning('Owner-only RPC socket failed to bind.', error, stack);
      }
    } else {
      // The deliberate opt-out: a caller has asked for loopback HTTP in code.
      _httpRpcEnabled = true;
    }

    // A privileged credential is minted only where a privileged transport
    // actually came up — there is nothing for it to authenticate to otherwise,
    // and an unpublishable secret on disk is pure downside.
    if (_socketServer != null || _httpRpcEnabled) {
      _token = _generateToken();
      // `/mcp` is gated on the *same* prerequisite, and deliberately so. It is
      // served over loopback, which the threat model above calls the weaker
      // boundary; making it available when the owner-only channel could not be
      // established would turn that weaker boundary into the only one, which is
      // exactly the silent downgrade `_withholdPrivilegedRpc` exists to
      // prevent. If nothing here can be hardened, nothing here is served.
      _mcpEndpoint!.token = _generateToken();
    }

    // Restrict the (still empty) handshake file before deciding what goes in
    // it, so a privileged token is never written under an ACL that was not
    // applied — not even for the instant before a follow-up `icacls`.
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
      // The handshake is the only way the token reaches the bridge. If it
      // cannot be locked to this account the token does not go in it — and a
      // privileged transport no legitimate caller can authenticate to is not
      // worth listening on, so it comes down too.
      stage ??= ControlServerFailureStage.handshakePermissions;
      detail ??= 'the handshake file ACL was not applied';
      await _withholdPrivilegedRpc();
    }
    await _publishHandshake(file, server.port);

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
    // Beside the handshake file rather than resolved separately: they belong in
    // the same application-support directory, and a second
    // `getApplicationSupportDirectory()` would be a platform-channel call on a
    // path every caller has already told us about.
    await _prepareSessionConfigs(
      sessionConfigDirectory ?? p.join(p.dirname(file.path), 'mcp'),
    );
    _publishSessionMcp(this);
    _startCheckpointRecorder();
    _tokenReaper.start();
  }

  /// Also listens on the WSL virtual switch's host address, so an agent inside
  /// a WSL distribution can dial `/mcp` at all.
  ///
  /// Most of this owner's agent sessions run in WSL, and until this existed
  /// every one of them was handed — or would have been handed — a URL its own
  /// network namespace refuses. [wslHostAddressAmong] records the measurement
  /// and why this address rather than `0.0.0.0`.
  ///
  /// Two rules hold it to the narrowest thing that works:
  ///
  /// * **Only what an agent in a distribution needs**, which is `/mcp` and
  ///   `/agent-hook`: [_handleWslInterface], not [_handle], so the privileged
  ///   `/rpc` envelope is not part of this decision and stays where it was.
  ///   The hook route belongs here for exactly the reason `/mcp` does — a hook
  ///   installed in a distro posting to `127.0.0.1` never arrives — and it is
  ///   the deliberately low-privilege half: it can report status and nothing
  ///   else, behind its own separate bearer token.
  ///
  ///   That is also why this is bound whether or not an MCP credential exists.
  ///   `/agent-hook` fails *open* when hardening fails — the rest of `start`
  ///   says why: an agent that cannot report status is a worse outcome than one
  ///   that cannot drive a device — and it would be a strange reading of that
  ///   rule to honour it for Windows panes and quietly drop it for the
  ///   environment most sessions run in. `/mcp` is unaffected: with no
  ///   credential it answers `401` here exactly as it does on loopback, so a
  ///   withheld credential stays withheld on both doors.
  /// * **Never fatal.** The port is already taken on that address, the switch
  ///   went away between the lookup and the bind, a future Windows renames the
  ///   adapter — each of those costs WSL sessions their tools and costs nothing
  ///   else. The app starts exactly as it did before.
  /// Binds the control port, preferring [preferredControlPort].
  ///
  /// Falling back is not a failure: everything on Windows works on any port.
  /// What is lost is WSL, and that loss is logged rather than left silent.
  Future<HttpServer> _bindControlPort(int preferred) async {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, preferred);
    } on SocketException catch (error) {
      _logger.info(
        'Port $preferred is taken, so this run uses an ephemeral '
        'one. Agents inside WSL will not be able to reach this server: the '
        'Hyper-V firewall rule the installer wrote names that one port. '
        '($error)',
      );
      return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
  }

  Future<void> _bindWslInterface(
    int port,
    Future<InternetAddress?> Function() lookup,
  ) async {
    try {
      final host = await lookup();
      if (host == null) {
        // Silently giving up here disabled WSL tools and WSL hooks for the
        // whole run. The owner hit exactly that: the app started at 11:25, the
        // switch was not enumerable at that instant, nothing was logged, and
        // every WSL session that day launched without its tools while the
        // adapter sat there the rest of the morning. The app looked once, at
        // the one moment it was least likely to be true — an app that starts
        // with Windows starts before WSL does.
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
      // The installer writes this address into agents' own config files, so it
      // has to be the address that was actually bound — published only after
      // the bind succeeded, never on the strength of the lookup alone.
      _hookEndpoint = AgentHookEndpoint(
        port: port,
        token: _hookEndpoint!.token,
        wslHost: host.address,
      );
      server.listen(
        _handleWslInterface,
        onError: (Object e) => _logger.warning('$e'),
      );
      _logger.info('MCP also on ${host.address}:$port, for WSL sessions.');
      final wasRetrying = _wslRetry != null;
      _cancelWslRetry();
      // Hooks were installed at startup, when this address did not exist, so
      // every WSL store was skipped. Nothing else would ever revisit that.
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

  /// Creates the owner-only directory per-session MCP configs go in, empty.
  ///
  /// Gated on a credential existing for the same reason [_bindWslInterface] is:
  /// a config naming an endpoint that answers `401` is a file with a secret in
  /// it and no use for it.
  Future<void> _prepareSessionConfigs(String dirPath) async {
    if (_mcpEndpoint?.token == null) return;
    _sessionConfigs = await SessionMcpConfigs.prepare(
      Directory(dirPath),
      (dir) => _permissions.restrictDirectory(dir, logger: _logger),
    );
    if (_sessionConfigs == null) {
      // Not fatal, and deliberately not: an agent that takes the URL on its
      // command line is unaffected, and one that needs a file launches without
      // it rather than with a credential nothing is guarding.
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

  /// Brings the per-turn checkpoint recorder to life.
  ///
  /// It has to be *read* by something or Riverpod never builds it, and it has no
  /// UI of its own to do the reading. This is the earliest thing in the app that
  /// runs once, holds the container, and is not in the widget tree. When the
  /// transcript grows its own checkpoint strip, that widget becomes the natural
  /// owner and this line goes away.
  void _startCheckpointRecorder() {
    try {
      _container.read(sessionCheckpointRecorderProvider);
    } on Object catch (error, stack) {
      _logger.warning('Checkpoint recorder failed to start.', error, stack);
    }
  }

  /// Creates the owner-only directory and binds the RPC socket inside it.
  ///
  /// The directory is restricted **before** the socket is created, so there is
  /// no window in which the socket exists under a permissive ACL — and if the
  /// restriction does not apply, the socket is never created at all. A unix
  /// domain socket carries no permissions of its own, so a directory whose ACL
  /// was not applied is the whole boundary missing, not a degraded one.
  Future<LocalRpcServer> _bindLocalSocket(String? overrideDirectory) async {
    final dirPath =
        overrideDirectory ??
        p.join((await getApplicationSupportDirectory()).path, 'ipc');
    final dir = Directory(dirPath);
    await dir.create(recursive: true);
    if (!await _permissions.restrictDirectory(dir, logger: _logger)) {
      throw _HardeningFailure(
        ControlServerFailureStage.socketDirectoryPermissions,
        'the owner-only ACL on $dirPath was not applied',
      );
    }
    final socketPath = p.join(dir.path, 'rpc.sock');
    final socket = await LocalRpcServer.bind(socketPath, _handleSocketRpc);
    _logger.info('Owner-only RPC socket at $socketPath.');
    return socket;
  }

  Future<void> stop() async {
    _cancelWslRetry();
    _tokenReaper.stop();
    await _server?.close(force: true);
    await _wslServer?.close(force: true);
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
    _publishSessionMcp(null);
    _sessionConfigs?.dispose();
    _sessionConfigs = null;
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

  /// Creates the handshake file **empty**, ready to be restricted.
  ///
  /// Nothing is written until the ACL has been applied and the caller has
  /// decided what may go in it, so the tokens never touch the disk under a
  /// permissive ACL. Any pre-existing file is removed first rather than
  /// overwritten, because a write preserves the DACL a file already carries.
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

  /// Publishes the port, the pid and whichever credentials survived hardening.
  ///
  /// `token` and `socketPath` appear only when a privileged transport is
  /// actually up: a bridge that finds neither is told, by their absence, that
  /// privileged RPC is not on offer. The hook port and token are always
  /// published — they are the low-privilege half that fails *open* by design.
  Future<void> _publishHandshake(File file, int port) async {
    await file.writeAsString(
      jsonEncode({
        'port': port,
        'pid': pid,
        'hookToken': _hookEndpoint!.token,
        'token': ?_token,
        if (_socketServer case final socket?) 'socketPath': socket.path,
        // The Streamable HTTP endpoint. Published under the same rule as the
        // rest: present only when a credential for it actually exists.
        'mcpToken': ?_mcpEndpoint?.token,
        if (_mcpEndpoint?.token != null)
          'mcpUrl': 'http://127.0.0.1:$port${McpHttpEndpoint.path}',
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
    // MCP proper, on its own single endpoint. It authenticates itself — with a
    // different credential and a different rule about who the caller is — so it
    // is routed before the `/rpc` bearer check rather than through it.
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
      // Which of *our* sessions is calling, when one is.
      //
      // The bridge reads it from its own environment, which Karmashala stamped
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
      final report = _container
          .read(agentHookReceiverProvider)
          .handle(
            agentId: request.uri.queryParameters['agent'],
            event: request.uri.queryParameters['event'],
            body: body,
          );
      // A callback naming a session we have no row for may be one the user
      // started by hand in one of our own panes. Synchronous and O(1) once a
      // session has been decided about, so a busy agent's stream of hooks costs
      // a set lookup — and wrapped, because adoption must never be able to fail
      // the callback and stall the agent that fired it.
      try {
        _container
            .read(sessionAdoptionServiceProvider)
            .onHookPayload(
              agentId: report.agentId,
              sessionId: report.sessionId,
              body: body,
            );
      } on Object catch (error) {
        _logger.warning('Session adoption from a hook failed: $error');
      }
      // The status pipeline's *primary* input. A hook is authoritative and
      // already in memory, so the registry folds it in here — one map lookup
      // and a precedence — rather than a poll discovering it up to five seconds
      // later. Wrapped for the same reason as adoption above.
      try {
        reportAgentHook(
          _container,
          agentId: report.agentId,
          sessionId: report.sessionId,
        );
      } on Object catch (error) {
        _logger.warning('Applying a hook report to the registry failed: $error');
      }
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

  bool _constantTimeEquals(String? actual, String expected) =>
      constantTimeEquals(actual, expected);

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
          permissionMode: args['permissionMode'] as String?,
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
      case 'session_handoff':
        return _sessionHandoff(
          sessionId: args['sessionId'] as String?,
          cli: args['cli'] as String?,
          agentInstallationId: args['agentInstallationId'] as String?,
          instruction: args['instruction'] as String?,
          unresolvedTasks: (args['unresolved'] as List?)
              ?.whereType<String>()
              .toList(),
          newWorktree: args['newWorktree'] == true,
          preview: args['preview'] == true,
        );
      case 'session_fork':
        return _sessionFork(
          sessionId: args['sessionId'] as String?,
          instruction: args['instruction'] as String?,
          newWorktree: args['newWorktree'] == true,
          preview: args['preview'] == true,
        );
      case 'open_sessions_in_tmux':
        return _openSessionsInTmux(
          (args['ids'] as List?)?.whereType<String>().toList() ??
              const <String>[],
          name: args['name'] as String?,
        );
      // The per-turn record of a working tree. Like the session tools below,
      // these default to the session that called them.
      case final String name when CheckpointControlTools.handles(name):
        return CheckpointControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      // Operating a session that already exists. Split out because these are
      // the half that needs the caller's own identity: every one of them
      // defaults to the session that called it.
      case final String name when SessionControlTools.handles(name):
        return SessionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      // What is written down, and what is waiting on somebody.
      case final String name when AttentionControlTools.handles(name):
        return AttentionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      // What was decided, as opposed to what was said. The one write path into
      // the decision record that is not attached to some other act.
      case final String name when DecisionControlTools.handles(name):
        return DecisionControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      // Review comments as threads a human triages: the reviewer files
      // findings here instead of into a transcript, and the author answers in
      // the same place the request was made.
      case final String name when ReviewThreadTools.handles(name):
        return ReviewThreadTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      // Where the work is: checkouts, and what one of them owes.
      case final String name when WorkspaceControlTools.handles(name):
        return WorkspaceControlTools(
          _container,
          callerSessionId: callerSessionId,
        ).call(name, args);
      // Making a checkout and taking one away. Separate from the workspace
      // tools above because those only read and select, and these are the two
      // verbs that change what is on disk — one of them irreversibly.
      case final String name when WorktreeControlTools.handles(name):
        return WorktreeControlTools(_container).call(name, args);
      // An attached phone or emulator, through the same AdbService the device
      // pane uses — so an agent and the person beside it drive one device.
      case final String name when DeviceControlTools.handles(name):
        return DeviceControlTools(_container).call(name, args);
      // The terminal workspace, through the same controller the tab bar uses,
      // so an agent's pane is a pane the user can see and take over.
      case final String name when TerminalControlTools.handles(name):
        return TerminalControlTools(_container).call(name, args);
      // The guides. Reads a table compiled into this binary, so it needs
      // neither the container nor the caller's identity — and answers even
      // when everything it describes is unavailable, which is exactly when an
      // agent is most likely to ask.
      case final String name when InstructionsTools.handles(name):
        return const InstructionsTools().call(name, args);
      // The browser tools live in features/browser and share the app's single
      // BrowserService with the browser pane, so an agent and the developer
      // drive the same page.
      //
      // The consent gate is resolved here rather than inside the feature
      // because "which project is this call for" is a question about sessions
      // and checkouts, and `features/browser` has no business reading those
      // tables. Passing it per dispatch also means a grant taken back in
      // Settings is in force on the very next call — there is nothing cached.
      case final String name when BrowserTools.handles(name):
        return BrowserTools(
          _container.read(browserServiceProvider),
          consent: browserConsentFor(
            _container,
            callerSessionId: callerSessionId,
          ),
        ).call(name, args);
      // Verification runs record what the browser and device tools above do,
      // so they share those same services rather than driving anything of their
      // own. The artifact root is resolved here because it is the first thing
      // that needs it and the app may not have asked for it yet.
      case final String name when VerificationTools.handles(name):
        await resolveVerificationRoot();
        final verification = _container.read(verificationServiceProvider);
        // The run being closed, noted *before* the call because finishing it
        // clears the service's active run. `verification_finish` is one of the
        // four explicit acts that write to a session's decision record (G1),
        // and this is the seam where it does — the verification feature is
        // another owner's and does not need to know the record exists.
        final finishing = name == 'verification_finish'
            ? verification.activeRun?.id
            : null;
        // The caller is the producer of every verdict recorded here (G3): the
        // one thing a self-graded run could never say about itself.
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
      'name': 'open_new_session',
      'description':
          'Start a NEW agent session (not a resume) in a project, as a terminal '
          'tab in Karmashala. Choose the agent with agentInstallationId (from '
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
          'permissionMode': {
            'type': 'string',
            'enum': ['ask', 'acceptEdits', 'bypass'],
            'description':
                'How much the new agent may do without asking. Omit to use '
                'the mode configured in Settings, which is what the '
                'New-session dialog does. "bypass" skips every prompt and is '
                'never a default; ask the user before choosing it for them.',
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
          'Open one session by its id. A Karmashala session that is still '
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
          'verification verdict and failure reason. Each verdict says who '
          'produced it: attribution is "author" when the candidate graded '
          'itself, "independent" when another session did, and "notRecorded" '
          'when nobody recorded a verifier — a self-graded pass is not '
          'evidence, so say which one it was when you report on a '
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
      'name': 'session_handoff',
      'description':
          'Continue an existing session in a different agent. Builds a handoff '
          'packet from that session — a quoted recap of its conversation, the '
          'files changed in the working tree, the current branch, anything '
          'listed as unresolved, and your instruction — and starts a new '
          'session with the packet as its first message, in the SAME worktree '
          'and on the SAME branch by default. The packet states its '
          'provenance: the new agent is told the conversation is not its own. '
          'The original session is left running and untouched; ending it is '
          'the user\'s decision. Use preview:true to read the packet without '
          'starting anything.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'sessionId': {
            'type': 'string',
            'description': 'Session id from list_sessions (kind "native").',
          },
          'cli': {
            'type': 'string',
            'description':
                'Agent to continue in: "claude" or "codex". Ignored when '
                'agentInstallationId is given.',
          },
          'agentInstallationId': {
            'type': 'string',
            'description': 'Specific installation id from list_agents.',
          },
          'instruction': {
            'type': 'string',
            'description':
                'What the receiving agent should do. Required: the packet '
                'carries the conversation, this is the part it cannot infer.',
          },
          'unresolved': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Work still open, listed for the new agent.',
          },
          'newWorktree': {
            'type': 'boolean',
            'description':
                'Start in a fresh Git worktree instead of continuing in the '
                'same one. Default false, which is what a handoff usually '
                'wants.',
          },
          'preview': {
            'type': 'boolean',
            'description':
                'Return the packet without starting anything. Read it before '
                'handing over work you care about.',
          },
        },
        'required': ['sessionId', 'instruction'],
      },
    },
    {
      'name': 'session_fork',
      'description':
          'Branch a session into a new one that shares its history up to now '
          'and then diverges. Runs the SAME agent — a fork is a branch of one '
          'conversation, not a change of provider. Uses the CLI\'s own fork '
          'when it has one and Karmashala knows the conversation id; '
          'otherwise it falls back to a handoff packet, and the result says '
          'which happened. The original session is untouched. Use preview:true '
          'to see which route would be taken before committing to it.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'sessionId': {
            'type': 'string',
            'description': 'Session id from list_sessions (kind "native").',
          },
          'instruction': {
            'type': 'string',
            'description':
                'Optional opening message for the branch. Leave it out to fork '
                'and wait.',
          },
          'newWorktree': {
            'type': 'boolean',
            'description':
                'Fork into a fresh Git worktree so the two branches do not '
                'edit the same files. Default false.',
          },
          'preview': {
            'type': 'boolean',
            'description': 'Report the plan without starting anything.',
          },
        },
        'required': ['sessionId'],
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
    ...instructionsToolSchemas,
    ...sessionControlToolSchemas,
    ...terminalControlToolSchemas,
    ...workspaceControlToolSchemas,
    ...worktreeControlToolSchemas,
    ...deviceControlToolSchemas,
    ...attentionControlToolSchemas,
    ...decisionControlToolSchemas,
    ...reviewThreadToolSchemas,
    ...browserToolSchemas,
    ...verificationToolSchemas,
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
                // Present even when null, unlike every optional field above.
                // An omitted producer reads as a gap in the tool rather than a
                // gap in the record, which is exactly how a self-graded pass
                // comes to be read as a checked one — the thing G3 exists to
                // stop. Every human-facing surface already says this; an agent
                // reading a comparison was the last one that could not.
                'producedBySessionId': evidence.producerSessionId,
                'attribution': candidate.evidenceAttribution.name,
                'attributionLabel': candidate.evidenceAttribution.label,
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
        // another agent) started in Karmashala could not be listed, opened or
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

  /// The permission mode named by a caller, or null to let the setting decide.
  ///
  /// Refuses an unknown name rather than falling back to the default. The
  /// modes are already decided in `permission_carry.dart`, and a typo silently
  /// becoming "ask" would look like the tool worked; a typo silently becoming
  /// anything else would be worse.
  PermissionMode? _parsePermissionMode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final wanted = raw.trim();
    for (final mode in PermissionMode.values) {
      if (mode.name == wanted) return mode;
    }
    throw ArgumentError(
      'Unknown permissionMode "$raw". One of: '
      '${PermissionMode.values.map((m) => m.name).join(', ')}.',
    );
  }

  Future<Object?> _openNewSession({
    String? projectId,
    String? cli,
    String? agentInstallationId,
    String? repositoryId,
    String? title,
    String? prompt,
    bool useWorktree = false,
    String? permissionMode,
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
      // here as it does in the New-session dialog.
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
          permissionOverride: _parsePermissionMode(permissionMode),
        ),
      );
      return {
        'sessionId': launched.session.id,
        'opened': 'new ${install.agentId} session',
        'title': launched.session.title,
        'repository': repo.name,
        'environmentId': repo.path.environmentId,
        'depth': launcher.depthForChildOf(callerSessionId).depth,
        'permissionMode': launched.session.permissionMode?.name ?? 'not recorded',
        if (launched.session.worktree != null)
          'worktree': launched.session.worktree!.path,
      };
    } on SessionDepthRefused catch (refused) {
      // Fail the caller's turn with the reason, rather than with a generic
      // error it might reasonably retry.
      throw StateError(refused.depth.refusal);
    }
  }

  /// Continues [sessionId] in another agent.
  ///
  /// The tool is deliberately thin: every decision — which targets exist,
  /// whether one can be told anything, what the permission mode becomes, what
  /// the packet says — belongs to `SessionHandoffService`, so an agent asking
  /// for a handoff and a user clicking one get the same answer. What is added
  /// here is `preview`, because a model that cannot see the dialog needs some
  /// way to read the packet before spending another agent's first turn on it.
  Future<Object?> _sessionHandoff({
    String? sessionId,
    String? cli,
    String? agentInstallationId,
    String? instruction,
    List<String>? unresolvedTasks,
    bool newWorktree = false,
    bool preview = false,
  }) async {
    if (sessionId == null) throw ArgumentError('Missing sessionId.');
    if (instruction == null || instruction.trim().isEmpty) {
      throw ArgumentError(
        'Missing instruction. The packet carries the conversation; the '
        'instruction is the part it cannot infer.',
      );
    }
    final service = _container.read(sessionHandoffServiceProvider);
    final targets = service.targetsFor(sessionId);
    if (targets.isEmpty) {
      throw StateError(
        'No agent is installed in that session\'s environment, or the session '
        'no longer exists.',
      );
    }
    final target = _handoffTarget(targets, cli, agentInstallationId);
    if (!target.canReceive) throw StateError(target.refusal!);

    if (preview) {
      final packet = await service.buildPacket(
        sessionId: sessionId,
        targetAgentName: target.agentName,
        instruction: instruction,
        unresolvedTasks: unresolvedTasks ?? const [],
      );
      return {
        'preview': true,
        'target': target.agentName,
        'permissionMode': target.permission.mode.name,
        'permission': target.permission.summary,
        'packet': packet.render(),
      };
    }

    final launched = await service.handoffTo(
      sessionId: sessionId,
      targetInstallationId: target.installation.id,
      instruction: instruction,
      unresolvedTasks: unresolvedTasks ?? const [],
      intoNewWorktree: newWorktree,
    );
    return {
      'sessionId': launched.session.id,
      'title': launched.session.title,
      'target': target.agentName,
      'parentSessionId': sessionId,
      'link': SessionLink.handoff.name,
      'permissionMode': target.permission.mode.name,
      'permission': target.permission.summary,
      if (launched.session.worktree != null)
        'worktree': launched.session.worktree!.path,
    };
  }

  /// Picks the target the caller named, preferring an explicit installation id
  /// over a CLI name. Never falls back to "some other agent": a handoff aimed
  /// at the wrong provider is not a smaller version of the right one.
  HandoffTarget _handoffTarget(
    List<HandoffTarget> targets,
    String? cli,
    String? agentInstallationId,
  ) {
    if (agentInstallationId != null) {
      for (final target in targets) {
        if (target.installation.id == agentInstallationId) return target;
      }
      throw StateError(
        'That agent installation is not available for this session.',
      );
    }
    if (cli != null) {
      final agentId = _parseCli(cli);
      for (final target in targets) {
        if (target.installation.agentId == agentId) return target;
      }
      throw StateError('$cli is not installed in that session\'s environment.');
    }
    // No preference stated: the first agent that is *not* the one already
    // running it, because "continue with another agent" is what was asked for.
    for (final target in targets) {
      if (!target.isSameAgent && target.canReceive) return target;
    }
    return targets.first;
  }

  Future<Object?> _sessionFork({
    String? sessionId,
    String? instruction,
    bool newWorktree = false,
    bool preview = false,
  }) async {
    if (sessionId == null) throw ArgumentError('Missing sessionId.');
    final service = _container.read(sessionHandoffServiceProvider);
    final plan = service.forkPlanFor(sessionId);
    if (preview) {
      return {
        'preview': true,
        'route': plan.kind.name,
        'explanation': plan.explanation,
      };
    }
    if (plan.isRefused) throw StateError(plan.explanation);

    final launched = await service.forkSession(
      sessionId: sessionId,
      instruction: instruction ?? '',
      intoNewWorktree: newWorktree,
    );
    return {
      'sessionId': launched.session.id,
      'title': launched.session.title,
      'parentSessionId': sessionId,
      'link': SessionLink.fork.name,
      // Said plainly, because the two are not equivalent: a native fork shares
      // the agent's own record, a handoff carries a written recap of it.
      'route': plan.kind.name,
      'explanation': plan.explanation,
      if (launched.session.worktree != null)
        'worktree': launched.session.worktree!.path,
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
    // Before the terminal is even resolved: this surface had no guard at all,
    // so an agent the resume builder could not express opened a terminal
    // running a *new* conversation and the tool reported success.
    final refusal = resumeRefusalFor(
      _container.read(agentRegistryProvider),
      session.cli,
      session.externalId,
    );
    if (refusal != null) throw StateError(refusal);
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
      registry: _container.read(agentRegistryProvider),
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
      // A directory that has gone means the agent is resumed at the repository
      // root instead, and its store is keyed by directory — so the caller is
      // told, rather than being left to wonder why the conversation is empty.
      'note': ?launched.workingDirectoryNotice,
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
      // The same registry read as every other resume surface. This switch was
      // the worst of the family: its `_` arm handed `--resume <id>` to *any*
      // agent, so an agent that spells it differently was given a flag it does
      // not have and the tmux window died on an unknown option — or, worse,
      // took `--resume` as something else entirely.
      final registry = _container.read(agentRegistryProvider);
      final refusal = resumeRefusalFor(
        registry,
        session.cli,
        session.externalId,
      );
      if (refusal != null) {
        throw StateError('Session "${session.displayTitle}": $refusal');
      }
      final parts = [
        install.executable.path,
        ...permissionArgsFor(
          session.cli,
          _permissionFor(session.cli),
          registry: registry,
        ),
        ...resumeArgsFor(session.cli, session.externalId, registry: registry),
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
    final sessionName = tmuxSafeName(name ?? 'karmashala', fallback: 'cg');
    final script = buildTmuxScript(sessionName, windows);

    // Write the script into the distro's /tmp via its UNC path, so nothing has
    // to survive quoting through the terminal → wsl → bash chain.
    final scriptWslPath =
        '/tmp/karmashala-tmux-${Random().nextInt(1 << 32)}.sh';
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

/// A hardening step that did not apply, thrown out of the privileged-transport
/// setup so `start` can fail closed with the reason intact.
class _HardeningFailure implements Exception {
  _HardeningFailure(this.stage, this.detail);

  final ControlServerFailureStage stage;
  final String detail;

  @override
  String toString() => detail;
}
