import 'dart:async';
import 'dart:io';

import '../domain/session_registry.dart';
import '../pty/posix_pty.dart';
import '../transport/socket_transport.dart';
import 'host_paths.dart';
import 'host_server.dart';

/// The daemon.
///
/// Started by the deployer as `setsid nohup … &` through an SSH exec channel,
/// so it is already out of that channel's process group by the time it runs.
/// What it has to do for itself is ignore SIGHUP: the channel closing must not
/// be the end of every session on the machine, which is the failure the whole
/// host exists to remove.
Future<int> runServe(List<String> args, {IOSink? out, IOSink? err}) async {
  final sink = out ?? stdout;
  final errSink = err ?? stderr;
  final paths = HostPaths.resolve();
  paths.ensureDirectory();

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

  final PosixPtyLauncher launcher;
  try {
    launcher = PosixPtyLauncher();
  } on ArgumentError catch (e) {
    errSink.writeln('karmashala_host: no usable libc on this machine: $e');
    lock.release();
    return 4;
  }

  final registry = SessionRegistry(launcher: launcher);
  final server = HostServer(registry: registry, ptyLibrary: launcher.ptyLibrary);
  final listener = await UnixSocketHostListener.bind(paths.socketPath);

  final stopping = Completer<int>();
  void stop(int code) {
    if (!stopping.isCompleted) stopping.complete(code);
  }

  // Nothing here is a timer. Each of these is an event the OS delivers.
  final subscriptions = <StreamSubscription<void>>[
    server.listen(listener),
    ProcessSignal.sigterm.watch().listen((_) => stop(0)),
    ProcessSignal.sigint.watch().listen((_) => stop(0)),
    // Ignored on purpose: an SSH channel closing sends this, and sessions
    // surviving that is the entire feature.
    ProcessSignal.sighup.watch().listen((_) {}),
  ];

  sink
    ..writeln('karmashala_host serving on ${listener.address}')
    ..writeln('pty library ${launcher.ptyLibrary}');
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
