import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_host/protocol.dart';

import '../../../core/logging/app_logger.dart';
import '../../ssh/data/host_deploy_target.dart';
import '../../ssh/data/host_session_access.dart';
import '../../ssh/domain/host_deployment.dart';
import 'host_pane_link.dart';

/// The session host on *this* machine, reached over its own socket.
///
/// The counterpart of `SshHostSessionAccess`, and deliberately the same
/// interface: the pane above it never learns which one it got, which is what
/// the transport seam in `host/lib/src/transport/transport.dart` was written
/// for. Two things are different, and both are because there is no network:
///
///  * **There is nothing to deploy.** The binary either ships beside this app
///    or it does not, and finding it is a measurement taken per launch rather
///    than a path stored once — the same rule §20 applies to agent executables.
///  * **There is nothing to reconnect.** A unix socket does not drop and come
///    back; if the host goes away the link ends and the pane says so. So
///    [reconnected] never fires, rather than firing on a timer nobody asked for.
class LocalHostSessionAccess implements HostSessionAccess {
  LocalHostSessionAccess({
    HostPaths? paths,
    this.executable = const LocalHostExecutable(),
    AppLogger? logger,
    this.startServe,
    this.helloBound = const Duration(seconds: 5),
  }) : _paths = paths ?? HostPaths.resolve(),
       _logger = logger ?? AppLogger.named('host.local');

  final HostPaths _paths;

  /// Where to look for the binary. Injectable because a test cannot put an
  /// executable beside the test runner.
  final LocalHostExecutable executable;

  /// How `serve` is started. Injectable for the same reason and no other: a
  /// test that starts a real daemon on the developer's own socket would take
  /// their sessions with it.
  final Future<Process> Function(String path)? startServe;

  /// How long the handshake is given before the answer is called missing.
  final Duration helloBound;

  final AppLogger _logger;

  Future<HostDeployment>? _reading;
  HostDeployment? _last;

  /// The last reading taken, or null when nobody has looked.
  ///
  /// Null is *unknown* and never a negative answer (§19): Settings says nothing
  /// has been checked rather than claiming the host is absent.
  HostDeployment? get lastReading => _last;

  @override
  String get address => 'this machine';

  /// Never fires. See the class comment: a local socket has no reconnect to
  /// hang on, and an empty stream is the honest way to say so — a pane that
  /// listens to it simply never re-dials.
  @override
  Stream<void> get reconnected => const Stream<void>.empty();

  String get socketPath => _paths.socketPath;

  @override
  Future<HostDeployment> deployment() =>
      // Memoised on the future, not the result: two panes opening at once must
      // share one measurement rather than racing two `serve` starts onto the
      // same lock.
      _reading ??= _measure().then((reading) {
        _logger.debug('local host: ${reading.status.name} — ${reading.reason}');
        // A reading nobody could take is a moment, not a fact (§19): the next
        // pane asks again rather than inheriting a busy one.
        if (reading.status == HostDeploymentStatus.unknown) _reading = null;
        return _last = reading;
      });

  /// Forgets the reading, so the next pane measures again.
  ///
  /// Called when a dial fails: the host we spoke to a moment ago may have been
  /// killed, and a remembered `ready` would send every later pane at a socket
  /// nothing is listening on.
  void forget() => _reading = null;

  /// Looks, and starts nothing.
  ///
  /// [deployment] is allowed to start a host because a pane is about to need
  /// one. A status row is not: somebody reading Settings with the setting off
  /// must not thereby launch a daemon. So this asks the same question with the
  /// same handshake and answers `unknown` when nothing is listening, carrying
  /// the time it was asked.
  Future<HostDeployment> observe() async {
    final binary = executable.locate();
    final answered = await _sayHello();
    final now = DateTime.now();
    return switch (answered) {
      _Welcomed(:final welcome) => _ready(
        welcome,
        binary?.path ?? '',
        restartedByUs: _last?.restartedByUs ?? false,
      ),
      _Mismatched(:final reason) => HostDeployment(
        status: HostDeploymentStatus.protocolMismatch,
        observedAt: now,
        reason: reason,
        remotePath: binary?.path,
      ),
      _NoAnswer(:final reason) => HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: now,
        reason: 'Could not finish the handshake on ${_paths.socketPath}: $reason',
        remotePath: binary?.path,
      ),
      _Silent() when binary == null => HostDeployment(
        status: HostDeploymentStatus.noBinary,
        observedAt: now,
        reason:
            'No ${LocalHostExecutable.fileName} beside this app '
            '(${executable.describeSearch()}).',
      ),
      _Silent() => HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: now,
        reason: 'Nothing is listening on ${_paths.socketPath}; no host is running here.',
        remotePath: binary?.path,
      ),
    };
  }

  @override
  Future<RemoteChannel> exec(String command) async {
    try {
      return SocketRemoteChannel(await _connect());
    } on SocketException {
      forget();
      rethrow;
    }
  }

  Future<Socket> _connect() => Socket.connect(
    InternetAddress(_paths.socketPath, type: InternetAddressType.unix),
    0,
    timeout: const Duration(seconds: 5),
  );

  Future<HostDeployment> _measure() async {
    final now = DateTime.now();
    final binary = executable.locate();
    if (binary == null) {
      return HostDeployment(
        status: HostDeploymentStatus.noBinary,
        observedAt: now,
        reason:
            'No ${LocalHostExecutable.fileName} was found beside this app or in '
            '${executable.describeSearch()}, so there is nothing to run here.',
        platform: _platform(now),
      );
    }

    final answered = await _sayHello();
    if (answered is _Welcomed) {
      return _ready(answered.welcome, binary.path, restartedByUs: false);
    }
    if (answered is _Mismatched) {
      return HostDeployment(
        status: HostDeploymentStatus.protocolMismatch,
        observedAt: DateTime.now(),
        reason: answered.reason,
        platform: _platform(now),
        remotePath: binary.path,
      );
    }

    if (answered is _NoAnswer) {
      // The one thing this must not do. A refused connection is an EVENT —
      // nobody is there, so start one. A handshake that ran out of bound is a
      // reading of a loaded machine, and acting on it starts a second daemon
      // over a live one: on 2026-09-09 that sent a test at a real
      // `Process.start`, the only await on this path with no bound at all.
      return HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: DateTime.now(),
        reason:
            'Could not finish the handshake on ${_paths.socketPath}: '
            '${answered.reason} Nothing was started over it.',
        platform: _platform(now),
        remotePath: binary.path,
      );
    }

    final started = await _start(binary);
    if (started != null) {
      return HostDeployment(
        status: HostDeploymentStatus.cannotStart,
        observedAt: DateTime.now(),
        reason: started,
        platform: _platform(now),
        remotePath: binary.path,
      );
    }

    final second = await _sayHello();
    if (second is _Welcomed) {
      return _ready(second.welcome, binary.path, restartedByUs: true);
    }
    return HostDeployment(
      status: HostDeploymentStatus.cannotStart,
      observedAt: DateTime.now(),
      reason:
          'Started ${binary.path}, but nothing answered on ${_paths.socketPath}'
          '${second is _Mismatched ? ' (${second.reason})' : ''}.',
      platform: _platform(now),
      remotePath: binary.path,
    );
  }

  HostDeployment _ready(
    WelcomeMessage welcome,
    String path, {
    required bool restartedByUs,
  }) => HostDeployment(
    status: HostDeploymentStatus.ready,
    observedAt: DateTime.now(),
    reason: restartedByUs
        ? 'Started the session host ${welcome.hostVersion} on this machine.'
        : 'The session host ${welcome.hostVersion} was already running here.',
    platform: HostPlatform(
      operatingSystem: welcome.operatingSystem,
      architecture: welcome.architecture,
      libc: HostLibc.unknown,
      observedAt: welcome.observedAt,
    ),
    remotePath: path,
    hostVersion: welcome.hostVersion,
    protocolVersion: welcome.protocolVersion,
    restartedByUs: restartedByUs,
  );

  /// This machine as the deployment record spells one, for the case where no
  /// host answered and there is nothing measured to report.
  HostPlatform _platform(DateTime observedAt) => HostPlatform(
    operatingSystem: Platform.operatingSystem,
    architecture: 'unknown',
    libc: HostLibc.unknown,
    observedAt: observedAt,
  );

  /// Opens a link, reads the welcome, and hangs up.
  ///
  /// The same `HostPaneLink` a pane uses, so the version check a pane would get
  /// is the version check the reading is made from — there is no second
  /// handshake to drift.
  Future<_HelloOutcome> _sayHello() async {
    final Socket socket;
    try {
      socket = await _connect();
    } on SocketException catch (e) {
      // Refused, or no node at all, is an event: nobody is there. A connect
      // that ran out of time is not — dart:io leaves `osError` null for that
      // one alone — and it says the machine was busy, not the socket empty.
      return e.osError == null ? _NoAnswer(e.message) : const _Silent();
    }
    final channel = SocketRemoteChannel(socket);
    try {
      final link = await HostPaneLink.open(
        channel,
        clientId: 'karmashala-probe',
        bound: helloBound,
      );
      final welcome = link.welcome;
      await link.close();
      return welcome == null ? const _Silent() : _Welcomed(welcome);
    } on HostLinkException catch (e) {
      await channel.close();
      // Three different answers, and only one of them means the socket is
      // empty. A host that answered and speaks another protocol, and one that
      // took the connection and said nothing inside the bound, both mean a
      // host IS there — this app must not start a second one over either.
      if (e.timedOut) return _NoAnswer(e.message);
      return e.message.contains('protocol') ? _Mismatched(e.message) : const _Silent();
    }
  }

  /// Starts `serve`, detached, and waits for it to say where it bound.
  ///
  /// Waited on rather than slept for: the daemon prints one line when the
  /// socket is up, and that line is the event. Returns null on success, or the
  /// sentence to refuse with.
  Future<String?> _start(File binary) async {
    final Process process;
    try {
      process =
          await (startServe?.call(binary.path) ??
              Process.start(
                binary.path,
                const ['serve'],
                // Detached, so it outlives this app — which is the entire point
                // — but with stdio, so the banner is readable. The host writes
                // nothing more after it, so a broken pipe once this app quits
                // costs nothing.
                mode: ProcessStartMode.detachedWithStdio,
              ));
    } on ProcessException catch (e) {
      return 'Could not start ${binary.path}: ${e.message}';
    }

    final ready = Completer<String?>();
    final said = StringBuffer();
    void look(String text) {
      said.write(text);
      if (!ready.isCompleted && said.toString().contains('serving on')) {
        ready.complete(null);
      }
    }

    process.stdout.transform(utf8.decoder).listen(look, onError: (Object _) {});
    process.stderr.transform(utf8.decoder).listen(look, onError: (Object _) {});
    unawaited(
      process.exitCode.then((code) {
        if (ready.isCompleted) return;
        // Exit 3 is "another host already holds the lock", which means one is
        // running after all — a race with another app instance, and not a
        // failure to report.
        ready.complete(
          code == 3 ? null : 'Started ${binary.path} and it exited $code: ${said.toString().trim()}',
        );
      }),
    );

    return ready.future.timeout(
      const Duration(seconds: 20),
      // A bound on a process that never printed anything, not a poll.
      onTimeout: () =>
          'Started ${binary.path}, but it did not report a socket within 20s: '
          '${said.toString().trim()}',
    );
  }
}

/// Where `karmashala_host` is on this machine, asked every time.
///
/// A stored path is state and whether it resolves is a measurement (§20): the
/// executable is found relative to `Platform.resolvedExecutable` per call, the
/// same discipline `karmashala_mcp` follows, so an app that moved or was
/// reinstalled needs nothing repaired.
class LocalHostExecutable {
  const LocalHostExecutable({this.executableDirectory, this.repositoryRoot});

  /// Overridable so a test can point at a directory it made.
  final String? executableDirectory;
  final String? repositoryRoot;

  static String get fileName =>
      Platform.isWindows ? 'karmashala_host.exe' : 'karmashala_host';

  List<String> _candidates() {
    final beside = executableDirectory ?? File(Platform.resolvedExecutable).parent.path;
    final root = repositoryRoot ?? Directory.current.path;
    return [
      '$beside/$fileName',
      // A debug run: `dart compile exe` writes here, and the release script
      // puts the cross-compiled ones beside it.
      '$root/host/build/$fileName',
    ];
  }

  File? locate() {
    for (final path in _candidates()) {
      final file = File(path);
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// The places that were looked in, for a refusal that names something.
  String describeSearch() => _candidates().join(', ');
}

/// A [RemoteChannel] over a plain socket.
///
/// The local half of the transport seam: `karmashala_host attach` exists so an
/// SSH exec channel can carry these bytes, and here there is no proxy at all —
/// the frames are identical, which is what made `attach` a byte proxy rather
/// than a protocol participant.
class SocketRemoteChannel implements RemoteChannel {
  SocketRemoteChannel(this._socket);

  final Socket _socket;
  final _exit = Completer<int>();

  @override
  Stream<Uint8List> get stdout => _socket;

  /// Nothing writes to this. A socket has one stream, and the host's diagnostics
  /// go to its own log rather than back down the channel.
  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  @override
  void add(Uint8List bytes) => _socket.add(bytes);

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> close() async {
    if (!_exit.isCompleted) _exit.complete(0);
    try {
      await _socket.close();
    } on SocketException {
      // The peer hung up first; there is nothing left to close politely.
    }
    _socket.destroy();
  }
}

sealed class _HelloOutcome {
  const _HelloOutcome();
}

class _Welcomed extends _HelloOutcome {
  const _Welcomed(this.welcome);
  final WelcomeMessage welcome;
}

/// Nothing was listening: the connection was refused, or the peer hung up.
class _Silent extends _HelloOutcome {
  const _Silent();
}

/// Something took the connection and did not finish the handshake in time.
///
/// A *reading*, not an event, which is the whole distinction: it says how busy
/// the machine was and nothing whatever about whether a host is running.
class _NoAnswer extends _HelloOutcome {
  const _NoAnswer(this.reason);
  final String reason;
}

class _Mismatched extends _HelloOutcome {
  const _Mismatched(this.reason);
  final String reason;
}
