import 'dart:async';
import 'dart:io';

import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionDao;
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../agents/server_agents.dart';
import '../automations/daemon_automations.dart';
import '../automations/session_mcp_access.dart';
import '../companion/daemon_companion.dart';
import '../domain/session_registry.dart';
import '../hooks/hook_endpoint_file.dart';
import '../hooks/hook_server.dart';
import '../mcp/daemon_mcp.dart';
import '../mcp/mcp_tool_relay.dart';
import '../pty/pty.dart';
import '../pty/pty_platform.dart';
import '../server/server_administration.dart';
import '../server/server_config.dart';
import '../server/server_config_service.dart';
import '../server/server_data_directory.dart';
import '../status/daemon_agent_status.dart';
import '../status/daemon_prompt_answers.dart';
import '../status/session_answer_tool.dart';
import '../transport/socket_transport.dart';
import 'package:karmashala_local_ipc/socket_location.dart';
import 'host_build.dart';
import 'host_paths.dart';
import 'host_server.dart';
import 'lifecycle_feed.dart';
import 'session_status_recording.dart';
import 'session_store.dart';
import 'surviving_sink.dart';

/// The daemon. Started detached — `setsid nohup … &` over SSH, or by the app on
/// Windows — and ignores SIGHUP, so an SSH channel closing is not the end of
/// every session on the machine.
///
/// One server, one way: its data directory is `--data-dir=<dir>`, or
/// [defaultServerDataDirectory] (`~/.karmashala`) — the one folder per user
/// per machine the desktop app opens too. The server owns what is in it: it
/// creates and migrates the store (`<dir>/karmashala.sqlite`, refusing one a
/// newer build migrated), reads `<dir>/server.json` (`ServerConfig`, each
/// field overridden by its flag, changed live with `server.config.set`),
/// finds the agent CLIs on its machine at start, and serves phones by that
/// config — off until something turns it on, and then on loopback unless
/// `companion.bind` says otherwise. [paths], [until] and [agentsFor] are for
/// tests.
///
/// [environment] is where the home (for the default data directory) and the
/// host directory are resolved from. It is never defaulted: without
/// `--data-dir` and [environment] — or without [paths] and [environment] —
/// the call is a programming error ([ArgumentError]), so a test cannot
/// reach the real `~/.karmashala` by leaving something out. Only the
/// executable passes `Platform.environment`.
Future<int> runServe(
  List<String> args, {
  Map<String, String>? environment,
  Duration agentScanDelay = const Duration(seconds: 5),
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Future<void>? until,
  ServerAgents Function(AppDatabase database)? agentsFor,
}) async {
  // Nobody may be reading either once the app that started this has quit;
  // a write that fails must cost the line, never the daemon.
  final sink = SurvivingSink(out ?? stdout);
  final errSink = SurvivingSink(err ?? stderr);
  final named = dataDirectoryOf(args);
  if (named == null && environment == null) {
    throw ArgumentError(
      'serve: pass --data-dir=<dir> or the environment to find the home in '
      '— the library never falls back to the real home',
    );
  }
  if (paths == null && environment == null) {
    throw ArgumentError(
      'serve: pass the host directory (paths) or the environment to resolve '
      'it from — the library never falls back to the real home',
    );
  }
  final String dataDirectory;
  try {
    dataDirectory =
        named ?? defaultServerDataDirectory(environment: environment!);
  } on StateError catch (error) {
    errSink.writeln('karmashala_host: refusing to serve — ${error.message}');
    return 2;
  }
  // The config is read, and refused, before anything binds: a server told
  // to bind somewhere it cannot parse must not bind somewhere else.
  final ServerConfigService config;
  try {
    await _ensurePrivateDirectory(dataDirectory);
    config = ServerConfigService(
      dataDirectory: dataDirectory,
      file: await ServerConfig.read(
        dataDirectory,
        log: (message) => errSink.writeln('karmashala_host: $message'),
      ),
      flags: ServerConfig.fromFlags(args),
      hostName: Platform.localHostname,
    );
  } on ServerConfigError catch (error) {
    errSink.writeln('karmashala_host: refusing to serve — $error');
    return 2;
  } on FileSystemException catch (error) {
    errSink.writeln(
      'karmashala_host: refusing to serve — $dataDirectory could not be made '
      'owner-only (${error.message})',
    );
    return 6;
  }
  paths ??= HostPaths.resolve(environment: environment!);
  paths.ensureDirectory();

  // Before the lock: a socket anybody can traverse to is a socket anybody can
  // drive, and there is nothing to authenticate with afterwards.
  final unrestricted = await paths.restrictToCurrentUser();
  if (unrestricted != null) {
    errSink.writeln(
      'karmashala_host: refusing to serve — the socket directory could not be '
      'made owner-only ($unrestricted)',
    );
    return 6;
  }

  // The socket goes where it fits: too long to bind in the host's directory — a
  // long or non-Latin home — and it moves somewhere short and private, proven
  // private before anything binds in it. Nowhere to go is refused in words,
  // not left to the OS's "the length of path exceeds the limit".
  switch (paths.socketLocation) {
    case PreferredSocketLocation():
      break;
    case final FallbackSocketLocation location:
      final refused =
          await prepareFallbackSocketDirectory(location) ??
          await HostPaths(
            Directory(location.directory),
          ).restrictToCurrentUser();
      if (refused != null) {
        errSink.writeln(
          'karmashala_host: refusing to serve — the socket directory could not '
          'be made owner-only ($refused)',
        );
        return 6;
      }
      sink.writeln('karmashala_host socket moved: ${location.reason}');
    case UnplaceableSocket(:final reason):
      errSink.writeln('karmashala_host: refusing to serve — $reason');
      return 6;
  }

  // One host per user per machine: the socket, lock, hook endpoint and
  // MCP credentials are the user's, whatever data directory a server has.
  // The refusal names the other server's data directory, so a second one
  // started beside it says whose socket it met.
  final lock = HostLock.tryAcquire(
    paths.lockPath,
    notePath: paths.holderDataDirectoryPath,
    dataDirectory: dataDirectory,
  );
  if (lock == null) {
    errSink.writeln(
      'karmashala_host: another host is already running for this user '
      '(${HostLock.describeHolder(paths.lockPath, notePath: paths.holderDataDirectoryPath)}); '
      'socket ${paths.socketPath}. One host serves each user on a machine: '
      'stop it (`karmashala_host stop`), or run this one as another user',
    );
    return 3;
  }

  // A socket left by a killed host refuses the bind; we hold the lock, so
  // nothing is listening on it.
  final stale = File(paths.socketPath);
  if (stale.existsSync()) stale.deleteSync();

  final PtyPlatform pty;
  try {
    pty = resolvePtyPlatform();
  } on PtyException catch (e) {
    errSink.writeln('karmashala_host: ${e.message}');
    lock.release();
    return 4;
  }

  // Read before anything binds, so the first client already sees what the last
  // host left — this server's records only: the directory is the user's, and
  // the desktop app's host or another server may have left theirs in it.
  final dataDir = Directory(dataDirectory);
  if (!dataDir.existsSync()) dataDir.createSync(recursive: true);
  final store = SessionStore(
    Directory(paths.sessionsDirectory),
    owner: storeOwnerOf(dataDirectory),
  )..ensureDirectory();
  final registry = SessionRegistry(launcher: pty.launcher, store: store);

  // The server's store, which the desktop app opens beside it: the pairings,
  // the host id and the rows whose lifecycle status this daemon alone
  // writes. A server with no store has nothing to pair into and no rows to
  // launch from: it is refused rather than half there.
  final database = _openStore(dataDirectory, errSink);
  if (database == null) {
    errSink.writeln(
      'karmashala_host: refusing to serve without a store — the line above '
      'says why',
    );
    lock.release();
    return 7;
  }
  final settings = config.settings;
  // What each hosted agent is doing, from the hooks and screens this host
  // holds, and the answers to what they ask.
  late final HostServer server;
  final status = DaemonAgentStatus(
    registry: registry,
    database: database,
    publish: (sessionId, body) =>
        server.lifecycle.publishAgentStatus(sessionId, body),
  );
  final prompts = DaemonPromptAnswers(status: status, database: database);
  final companion = DaemonCompanion(
    database: database,
    registry: registry,
    hostName: settings.name,
    dataDirectory: dataDirectory,
    lanPort: settings.companionPort,
    lanAddress: settings.bind,
    config: settings.companion,
    prompts: prompts,
    onLog: (message) => errSink.writeln('karmashala_host: $message'),
  );

  final mcpTools = McpToolRelay(cachePath: paths.mcpToolsPath);
  server = HostServer(
    registry: registry,
    ptyLibrary: pty.library,
    companion: companion,
    build: hostBuildOf(Platform.resolvedExecutable),
    mcpTools: mcpTools,
  )..prompts = prompts;
  server.lifecycle.statusSnapshot = status.snapshot;
  status.start();
  final recording = SessionStatusRecording(
    server.lifecycle,
    database,
    clock: () => DateTime.now().toUtc(),
  )..start();
  final companionServing = await _startCompanion(
    companion,
    server.lifecycle,
    status,
    errSink,
  );
  final hookServer = await _openHookServer(
    paths,
    server.lifecycle,
    status,
    errSink,
  );
  final mcp = await _openMcp(
    paths,
    dataDirectory,
    mcpTools,
    database,
    settings.mcpPort,
    errSink,
  );
  // A phone starts and resumes sessions here with no app, once a launched
  // agent can be handed its tools.
  companion.serveSessions(
    mcp: SessionMcpAccessPoint(
      mcp: mcp,
      configDirectory: p.join(dataDirectory, 'mcp'),
    ),
  );
  final automations = await _startAutomations(
    database: database,
    recording: recording,
    registry: registry,
    server: server,
    mcp: mcp,
    mcpTools: mcpTools,
    dataDirectory: dataDirectory,
    errSink: errSink,
    agentStatus: status,
  );
  // `session_answer` for a session this host holds is answered here; every
  // other local tool is the automations', and the rest go to the app.
  final automationsTool = mcpTools.local;
  mcpTools.local = (tool, arguments, caller) =>
      sessionAnswerTool(prompts, tool, arguments, caller) ??
      automationsTool?.call(tool, arguments, caller);
  // `server.config.set` brings the phone listener in line at once.
  if (companionServing) {
    config.apply = (settings) => companion.reconfigure(
      config: settings.companion,
      lanAddress: settings.bind,
      lanPort: settings.companionPort,
    );
  }
  // Devices, revoke, agents and the config, from `karmashala_host` and the
  // desktop app on this machine; the server looks for its agent CLIs now.
  final agents = (agentsFor ?? (database) => ServerAgents(database: database))(
    database,
  );
  server.admin = ServerAdministration(
    companion: companionServing ? companion : null,
    agents: agents,
    config: config,
    dataDirectory: dataDirectory,
  );
  final remembered = registry.sessions.length;
  final listener = await UnixSocketHostListener.bind(paths.socketPath);

  final stopping = Completer<int>();
  void stop(int code) {
    if (!stopping.isCompleted) stopping.complete(code);
  }

  // Not in the first moments: the probe starts a dozen processes, and a
  // server SIGKILLed while the VM is between fork and exec for one of them
  // can leave that half-born child behind for good, holding the socket —
  // connections accepted, never answered (found live: a start killed at
  // once). A server killed that early probes nothing; `agents.refresh`
  // still probes at once when asked.
  unawaited(
    Future<void>.delayed(agentScanDelay).then((_) async {
      if (stopping.isCompleted) return;
      try {
        final scan = await agents.refresh();
        sink.writeln('agents: ${scan.summary}');
      } on Object catch (error) {
        errSink.writeln('karmashala_host: agent probe failed ($error)');
      }
    }),
  );

  // Asked by platform: SIGINT is the only signal Windows has, and watching
  // SIGTERM there throws errno 50 from `onListen`'s own microtask, where no
  // try/catch around `listen` can see it.
  final subscriptions = <StreamSubscription<void>>[
    server.listen(listener),
    if (until != null) until.asStream().listen((_) => stop(0)),
    ProcessSignal.sigint.watch().listen((_) => stop(0)),
    if (!Platform.isWindows) ...[
      ProcessSignal.sigterm.watch().listen((_) => stop(0)),
      // Ignored on purpose: an SSH channel closing sends this.
      ProcessSignal.sighup.watch().listen((_) {}),
    ],
  ];

  sink
    ..writeln('karmashala_host serving on ${listener.address}')
    ..writeln('server "${settings.name}", data in $dataDirectory')
    ..writeln('pty library ${pty.library}')
    ..writeln(
      hookServer == null
          ? 'agent hooks unavailable — the line above says why'
          : 'agent hooks on port ${hookServer.port}',
    )
    ..writeln(
      mcp == null
          ? 'agent tools unavailable — the line above says why'
          : mcp.serving
          ? 'agent tools on port ${mcp.endpoint.port}'
          : 'agent tools refused — the line above says why',
    )
    ..writeln('store ${p.join(dataDirectory, kStoreFileName)}')
    ..writeln(
      automations == null
          ? 'automations unavailable — the line above says why'
          : 'automations scheduled here',
    )
    ..writeln(
      !companionServing
          ? 'companion unavailable — the line above says why'
          : companion.service == null
          ? 'companion off — remote access is switched off '
                '(companion.enabled in server.json), '
                '${companion.paired()} phone(s) paired'
          : 'companion on port ${companion.port} (bound to ${settings.bind}), '
                '${companion.paired()} phone(s) paired',
    )
    // Said out loud: coming back with nothing and coming back with four dead
    // sessions are different situations.
    ..writeln(
      'restored $remembered session(s) from ${paths.sessionsDirectory}',
    );
  await sink.flush();

  final code = await stopping.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await listener.close();
  await hookServer?.close();
  await mcp?.close();
  mcpTools.close();
  await companion.close();
  await status.close();
  // Before the sessions end: a check the shutdown kills is not a verdict.
  await automations?.close();
  await recording.close();
  await registry.shutdown();
  database.close();
  lock.release();
  // Bounded: a reader that is there but not reading must not hold the exit.
  await Future.wait([
    sink.flush(),
    errSink.flush(),
  ]).timeout(const Duration(seconds: 1), onTimeout: () => const []);
  return code;
}

/// The loopback hook listener, on the last run's port and token when that port
/// is still free, with [HostPaths.hookEndpointPath] written for the app. Null,
/// reported, when either fails: sessions do not need hooks.
Future<HookServer?> _openHookServer(
  HostPaths paths,
  LifecycleFeed lifecycle,
  DaemonAgentStatus? status,
  IOSink errSink,
) async {
  final previous = HookEndpoint.read(paths.hookEndpointPath);
  HookServer? server;
  try {
    server = await HookServer.bind(
      // The status first, so a watcher hears the status a hook moved no later
      // than the hook itself.
      onHook: (hook) {
        status?.hook(hook);
        return lifecycle.relayHook(hook);
      },
      port: previous?.port ?? 0,
      token: previous?.token,
    );
    await server.endpoint.write(paths.hookEndpointPath);
    return server;
  } on Object catch (error) {
    await server?.close();
    errSink.writeln('karmashala_host: no agent hook endpoint ($error)');
    return null;
  }
}

/// The MCP endpoint agents dial, with the handshake in [dataDirectory] where
/// the app and the bridge look. Null, reported, when it cannot start.
Future<DaemonMcp?> _openMcp(
  HostPaths paths,
  String dataDirectory,
  McpToolRelay relay,
  AppDatabase? database,
  int preferredPort,
  IOSink errSink,
) async {
  try {
    final sessions = database == null ? null : SessionDao(database);
    return await DaemonMcp.start(
      paths: paths,
      dataDirectory: dataDirectory,
      relay: relay,
      sessionIsOver: sessions == null
          ? null
          : (sessionId) => sessions.getById(sessionId)?.isOver ?? true,
      preferredPort: preferredPort,
      log: (message) => errSink.writeln('karmashala_host: $message'),
    );
  } on Object catch (error) {
    errSink.writeln('karmashala_host: no MCP endpoint ($error)');
    return null;
  }
}

/// The shared store at `<dataDirectory>/karmashala.sqlite`, or null, reported,
/// when this machine cannot hold one: sessions do not need a store, and a host
/// that refused to serve them for want of one would trade the larger thing for
/// the smaller. `karmashala_host probe-store` says which of four things failed.
AppDatabase? _openStore(String dataDirectory, IOSink errSink) {
  try {
    final directory = Directory(dataDirectory);
    if (!directory.existsSync()) directory.createSync(recursive: true);
    // Refused when a newer build migrated it: this one would write tables
    // it does not know the shape of.
    return AppDatabase.open(directory, refuseNewerSchema: true);
  } on Object catch (error) {
    errSink.writeln(
      'karmashala_host: no store in $dataDirectory ($error) — run '
      '`probe-store` here',
    );
    return null;
  }
}

/// The scheduler, runs and checks, on the shared store. Null, reported, when
/// there is no store or they cannot start: sessions do not need automations.
Future<DaemonAutomations?> _startAutomations({
  required AppDatabase? database,
  required SessionStatusRecording? recording,
  required SessionRegistry registry,
  required HostServer server,
  required DaemonMcp? mcp,
  required McpToolRelay mcpTools,
  required String dataDirectory,
  required IOSink errSink,
  DaemonAgentStatus? agentStatus,
}) async {
  if (database == null || recording == null) return null;
  final automations = DaemonAutomations(
    database: database,
    registry: registry,
    dataDirectory: dataDirectory,
    mcp: SessionMcpAccessPoint(
      mcp: mcp,
      configDirectory: p.join(dataDirectory, 'mcp'),
    ),
    announce: server.lifecycle.publishAutomationsChanged,
    log: (message) => errSink.writeln('karmashala_host: $message'),
  );
  try {
    server.automations = automations;
    mcpTools.local = automations.localTool;
    await automations.start(
      recording.changes,
      agentStatus: agentStatus?.changes,
    );
    return automations;
  } on Object catch (error) {
    server.automations = null;
    mcpTools.local = null;
    await automations.close();
    errSink.writeln('karmashala_host: automations did not start ($error)');
    return null;
  }
}

/// Starts serving phones. False, reported, when it cannot: sessions do not
/// need a companion.
Future<bool> _startCompanion(
  DaemonCompanion companion,
  LifecycleFeed lifecycle,
  DaemonAgentStatus? status,
  IOSink errSink,
) async {
  try {
    await companion.start(
      sessionEvents: lifecycle.events,
      statusChanges: status?.changes,
    );
    return true;
  } on Object catch (error) {
    errSink.writeln('karmashala_host: could not start the companion ($error)');
    return false;
  }
}

/// `--data-dir=<dir>`, absolute, or null when missing or empty.
String? dataDirectoryOf(List<String> args) {
  const flag = '--data-dir=';
  for (final arg in args) {
    if (!arg.startsWith(flag)) continue;
    final value = arg.substring(flag.length).trim();
    if (value.isNotEmpty) return p.absolute(value);
  }
  return null;
}

/// Creates [directory] if it is not there and makes it owner-only: the
/// server's store holds every phone's pairing key.
Future<void> _ensurePrivateDirectory(String directory) async {
  final dir = Directory(directory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final refused = await HostPaths(dir).restrictToCurrentUser();
  if (refused != null) throw FileSystemException(refused, directory);
}
