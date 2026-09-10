import 'dart:async';
import 'dart:io';

import '../domain/session_registry.dart';
import '../pty/pty.dart';
import '../pty/pty_platform.dart';
import '../transport/socket_transport.dart';
import 'host_paths.dart';
import 'host_server.dart';
import 'session_store.dart';

/// The daemon. Started detached — `setsid nohup … &` over SSH, or by the app on
/// Windows — and ignores SIGHUP, so an SSH channel closing is not the end of
/// every session on the machine.
Future<int> runServe(List<String> args, {IOSink? out, IOSink? err}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final paths = HostPaths.resolve();
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
  final store = SessionStore(Directory(paths.sessionsDirectory))..ensureDirectory();
  final registry = SessionRegistry(launcher: pty.launcher, store: store);
  final server = HostServer(registry: registry, ptyLibrary: pty.library);
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
    // Said out loud: coming back with nothing and coming back with four dead
    // sessions are different situations.
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
