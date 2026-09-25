import 'dart:async';
import 'dart:io';

import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart'
    show SessionDao;
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;

import '../companion/daemon_companion.dart';
import '../domain/session_registry.dart';
import '../hooks/hook_endpoint_file.dart';
import '../hooks/hook_server.dart';
import '../mcp/daemon_mcp.dart';
import '../mcp/mcp_endpoint_server.dart';
import '../mcp/mcp_tool_relay.dart';
import '../pty/pty.dart';
import '../pty/pty_platform.dart';
import '../transport/socket_transport.dart';
import 'package:karmashala_local_ipc/socket_location.dart';
import 'host_build.dart';
import 'host_paths.dart';
import 'host_server.dart';
import 'lifecycle_feed.dart';
import 'session_status_recording.dart';
import 'session_store.dart';

/// The daemon. Started detached — `setsid nohup … &` over SSH, or by the app on
/// Windows — and ignores SIGHUP, so an SSH channel closing is not the end of
/// every session on the machine.
///
/// `--data-dir=<dir>` is required: the store is `<dir>/karmashala.sqlite`, the
/// app's own file. [paths] and [until] are for tests.
Future<int> runServe(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  HostPaths? paths,
  Future<void>? until,
}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  // Refused before anything is touched: every caller is ours and passes it,
  // and a host run without it would record no session's status, silently.
  final dataDirectory = dataDirectoryOf(args);
  if (dataDirectory == null) {
    errSink.writeln(
      'karmashala_host: refusing to serve — `--data-dir=<dir>` is required; '
      'the store is <dir>/karmashala.sqlite, the app\'s own database',
    );
    return 2;
  }
  paths ??= HostPaths.resolve();
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

  final lock = HostLock.tryAcquire(paths.lockPath);
  if (lock == null) {
    errSink.writeln(
      'karmashala_host: another host is already running for this user '
      '(${HostLock.describeHolder(paths.lockPath)}); socket ${paths.socketPath}',
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
  // host left.
  final store = SessionStore(Directory(paths.sessionsDirectory))
    ..ensureDirectory();
  final registry = SessionRegistry(launcher: pty.launcher, store: store);

  // The app's own database, shared: its pairings, its host id and the rows
  // whose lifecycle status this daemon alone writes. Allowed to be absent — a
  // machine whose SQLite will not load still owns every PTY on it — and then
  // `pair` refuses by name and no status is recorded.
  final database = _openStore(dataDirectory, errSink);
  final companion = database == null
      ? null
      : DaemonCompanion(
          database: database,
          registry: registry,
          hostName: Platform.localHostname,
          lanPort: _companionPort(args),
          onLog: (message) => errSink.writeln('karmashala_host: $message'),
        );

  final mcpTools = McpToolRelay(cachePath: paths.mcpToolsPath);
  final server = HostServer(
    registry: registry,
    ptyLibrary: pty.library,
    companion: companion,
    build: hostBuildOf(Platform.resolvedExecutable),
    mcpTools: mcpTools,
  );
  final recording = database == null
      ? null
      : (SessionStatusRecording(
          server.lifecycle,
          database,
          clock: () => DateTime.now().toUtc(),
        )..start());
  final companionServing =
      companion != null &&
      await _startCompanion(companion, server.lifecycle, errSink);
  final hookServer = await _openHookServer(paths, server.lifecycle, errSink);
  final mcp = await _openMcp(
    paths,
    dataDirectory,
    mcpTools,
    database,
    _mcpPort(args),
    errSink,
  );
  final remembered = registry.sessions.length;
  final listener = await UnixSocketHostListener.bind(paths.socketPath);

  final stopping = Completer<int>();
  void stop(int code) {
    if (!stopping.isCompleted) stopping.complete(code);
  }

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
    ..writeln(
      database == null
          ? 'no store — session status is not recorded; the line above says why'
          : 'store ${p.join(dataDirectory, 'karmashala.sqlite')}',
    )
    ..writeln(
      companion == null || !companionServing
          ? 'companion unavailable — the line above says why'
          : companion.service == null
          ? 'companion off — remote access is switched off in the app, '
                '${companion.paired()} phone(s) paired'
          : 'companion on port ${companion.port}, '
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
  await companion?.close();
  await recording?.close();
  await registry.shutdown();
  database?.close();
  lock.release();
  return code;
}

/// The loopback hook listener, on the last run's port and token when that port
/// is still free, with [HostPaths.hookEndpointPath] written for the app. Null,
/// reported, when either fails: sessions do not need hooks.
Future<HookServer?> _openHookServer(
  HostPaths paths,
  LifecycleFeed lifecycle,
  IOSink errSink,
) async {
  final previous = HookEndpoint.read(paths.hookEndpointPath);
  HookServer? server;
  try {
    server = await HookServer.bind(
      onHook: lifecycle.relayHook,
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
    return AppDatabase.open(directory);
  } on Object catch (error) {
    errSink.writeln(
      'karmashala_host: no store in $dataDirectory ($error) — run '
      '`probe-store` here',
    );
    return null;
  }
}

/// Starts serving phones. False, reported, when it cannot: sessions do not
/// need a companion.
Future<bool> _startCompanion(
  DaemonCompanion companion,
  LifecycleFeed lifecycle,
  IOSink errSink,
) async {
  try {
    await companion.start(sessionEvents: lifecycle.events);
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

/// `--mcp-port=<n>`, asked for when no earlier port is remembered. A probe's
/// host passes 0, so it never takes the real one's port.
int _mcpPort(List<String> args) {
  const flag = '--mcp-port=';
  for (final arg in args) {
    if (!arg.startsWith(flag)) continue;
    final parsed = int.tryParse(arg.substring(flag.length));
    if (parsed != null && parsed >= 0 && parsed <= 65535) return parsed;
  }
  return kPreferredMcpPort;
}

/// `--companion-port=<n>`, or the shared default. 0 asks the OS for a free one,
/// which is what a second host on the same machine wants — a phone is told a
/// port, so the real one never wanders.
int _companionPort(List<String> args) {
  const flag = '--companion-port=';
  for (final arg in args) {
    if (!arg.startsWith(flag)) continue;
    final parsed = int.tryParse(arg.substring(flag.length));
    if (parsed != null && parsed >= 0 && parsed <= 65535) return parsed;
  }
  return kHostCompanionPort;
}
