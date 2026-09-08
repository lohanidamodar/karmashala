import 'dart:async';
import 'dart:io';

import '../domain/session_registry.dart';
import '../pty/pty.dart';
import '../pty/pty_platform.dart';
import '../transport/socket_transport.dart';
import 'host_paths.dart';
import 'host_server.dart';
import 'session_store.dart';

/// The daemon.
///
/// Started by the deployer as `setsid nohup … &` through an SSH exec channel,
/// so it is already out of that channel's process group by the time it runs.
/// What it has to do for itself is ignore SIGHUP: the channel closing must not
/// be the end of every session on the machine, which is the failure the whole
/// host exists to remove.
///
/// On Windows it is started by the app instead, detached, and hosts ConPTY
/// rather than POSIX ptys — the same server, the same socket, the same
/// protocol. Which pty layer it is running is a reading it reports in `hello`.
Future<int> runServe(List<String> args, {IOSink? out, IOSink? err}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final paths = HostPaths.resolve();
  paths.ensureDirectory();

  // The boundary before the lock: a socket in a directory anybody can traverse
  // is a socket anybody can drive, and there is nothing to authenticate with
  // afterwards. Fail closed, the way the app's privileged RPC does.
  final unrestricted = await paths.restrictToCurrentUser();
  if (unrestricted != null) {
    errSink.writeln(
      'karmashala_host: refusing to serve — the socket directory could not be '
      'made owner-only ($unrestricted)',
    );
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

  // A socket file left by a host that was killed would refuse the bind. We
  // only reach here holding the lock, so nothing is listening on it.
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

  // Read before anything binds, so the first client to connect already sees
  // what the last host left — including the sessions that were running when it
  // stopped, which come back ended with no exit code and a reason saying so.
  final store = SessionStore(Directory(paths.sessionsDirectory))..ensureDirectory();
  final registry = SessionRegistry(launcher: pty.launcher, store: store);
  final server = HostServer(registry: registry, ptyLibrary: pty.library);
  final remembered = registry.sessions.length;
  final listener = await UnixSocketHostListener.bind(paths.socketPath);

  final stopping = Completer<int>();
  void stop(int code) {
    if (!stopping.isCompleted) stopping.complete(code);
  }

  // Nothing here is a timer. Each of these is an event the OS delivers.
  //
  // SIGINT is the only one Windows has. `watch()` there answers "Failed to
  // listen for SIGTERM … The request is not supported (errno 50)" — measured
  // 2026-09-09, and it arrives from `onListen`'s own microtask, so it is an
  // *unhandled* exception a try/catch around `listen` never sees: the daemon
  // printed its banner and died a moment later, leaving a lock file, no socket
  // and a client that could only report "connection refused". Asked by platform
  // for that reason.
  final subscriptions = <StreamSubscription<void>>[
    server.listen(listener),
    ProcessSignal.sigint.watch().listen((_) => stop(0)),
    if (!Platform.isWindows) ...[
      ProcessSignal.sigterm.watch().listen((_) => stop(0)),
      // Ignored on purpose: an SSH channel closing sends this, and sessions
      // surviving that is the entire feature.
      ProcessSignal.sighup.watch().listen((_) {}),
    ],
  ];

  sink
    ..writeln('karmashala_host serving on ${listener.address}')
    ..writeln('pty library ${pty.library}')
    // Counted, and said out loud: a host that came back holding nothing and one
    // that came back holding four dead sessions are different situations, and
    // the difference is what the log is for.
    ..writeln('restored $remembered session(s) from ${paths.sessionsDirectory}');
  await sink.flush();

  final code = await stopping.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await listener.close();
  await registry.shutdown();
  lock.release();
  return code;
}
