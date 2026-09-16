import 'dart:async';
import 'dart:io';

import 'package:karmashala_remote/pairing.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_store/database.dart';

import '../companion/companion_listener.dart';
import '../companion/companion_port_number.dart';
import '../companion/host_pairing_service.dart';
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

  // The companion half, and it is allowed to be absent. A machine whose SQLite
  // will not load still owns every PTY on it, and taking panes away because a
  // phone could not have been served would be the larger failure — so this is
  // reported and stepped over, and `pair` refuses by name until it is fixed.
  // `karmashala_host probe-store` says which of the four things is wrong.
  final companion = await _openCompanion(
    paths,
    registry,
    _companionPort(args),
    errSink,
  );

  final server = HostServer(
    registry: registry,
    ptyLibrary: pty.library,
    openPairing: companion?.openPairing,
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
      companion == null
          ? 'companion unavailable — the line above says why'
          : 'companion on port ${companion.listener.port}, '
                '${companion.paired()} phone(s) paired',
    )
    // Said out loud: coming back with nothing and coming back with four dead
    // sessions are different situations.
    ..writeln('restored $remembered session(s) from ${paths.sessionsDirectory}');
  await sink.flush();

  final code = await stopping.future;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await listener.close();
  await companion?.close();
  await registry.shutdown();
  lock.release();
  return code;
}

/// The store, the pairing service and the phone listener, or null when this
/// machine cannot hold a store. Every failure is reported and none is fatal:
/// sessions do not need a store, and a host that refused to serve them because
/// a phone could not be paired would be trading the larger thing for the
/// smaller one.
Future<_Companion?> _openCompanion(
  HostPaths paths,
  SessionRegistry registry,
  int port,
  IOSink errSink,
) async {
  // The store and the listener fail for unrelated reasons and want unrelated
  // answers — `probe-store` for one, a busy port for the other — so they are
  // never reported as each other. Saying "no store" about a machine whose
  // SQLite opened perfectly is the confident false statement §19 is about.
  final AppDatabase database;
  try {
    database = AppDatabase.open(paths.storeDirectory);
  } on Object catch (error) {
    errSink.writeln(
      'karmashala_host: no companion store ($error) — run `probe-store` here',
    );
    return null;
  }

  try {
    final name = Platform.localHostname;
    final pairing = HostPairingService(
      database: database,
      hostName: name,
      hostId: _hostIdentity(database),
    );
    final listener = CompanionListener(
      registry: registry,
      hostName: name,
      devices: pairing.paired,
      onLog: (message) => errSink.writeln('karmashala_host: $message'),
    );
    await listener.start(port: port);
    return _Companion(database, pairing, listener);
  } on SocketException catch (error) {
    database.close();
    errSink.writeln(
      'karmashala_host: the store is fine but port $port is not free '
      '(${error.osError?.message ?? error.message}). Another host is probably '
      'already serving phones here; `--companion-port=<n>` picks another, and 0 '
      'asks the OS for a free one.',
    );
    return null;
  } on Object catch (error) {
    database.close();
    errSink.writeln('karmashala_host: could not start the companion ($error)');
    return null;
  }
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

/// This host's own id, minted once and kept.
///
/// A phone pins it, so a host that minted a fresh one each start would look
/// like a different machine every morning and every pairing would be stale. It
/// lives in `app_metadata`, which is the store's own table for exactly this.
DeviceId _hostIdentity(AppDatabase database) {
  const key = 'companion.host_id';
  final stored = database.readMetadata(key);
  if (stored != null) {
    try {
      return DeviceId.parse(stored);
    } on Object {
      // A value that will not parse is worse than none: it would refuse every
      // pairing forever. Replaced, and the old pairings go with it — which is
      // honest, because they were pinned to an id nothing can read.
    }
  }
  final minted = DeviceId.generate();
  // `value`, not `toString()`: that one is decorated `DeviceId(…)` and would
  // never parse back, so every restart would look like a new machine.
  database.writeMetadata(key, minted.value);
  return minted;
}

/// The companion half of a serving host, held together so it closes together.
class _Companion {
  _Companion(this._database, this._pairing, this.listener);

  final AppDatabase _database;
  final HostPairingService _pairing;
  final CompanionListener listener;

  int paired() => _pairing.paired().length;

  /// Opens a window and answers what to type. The listener routes the phone's
  /// link when it arrives, which is why this lives beside it rather than in the
  /// pairing service.
  Future<({String code, DateTime expiresAt})> openPairing(
    int capabilities,
    String relay,
  ) async {
    final session = await _pairing.open(
      // A box with its own address needs no relay, and says so by naming
      // itself; the payload carries a rendezvous either way.
      relay: relay.isEmpty ? Uri.parse('https://invalid.local') : Uri.parse(relay),
      grant: CapabilitySet(capabilities),
    );
    listener.acceptPairing(session);
    return (
      code: PairingCode.encode(session.payload.typedSecret!),
      expiresAt: session.deadline,
    );
  }

  Future<void> close() async {
    await listener.stop();
    _database.close();
  }
}
