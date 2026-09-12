import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_host/host_paths.dart';
import 'package:karmashala_host/protocol.dart';

import 'package:karmashala_core/logging.dart';
import 'package:karmashala_ssh/host.dart';
import 'host_pane_link.dart';

/// The session host on *this* machine, over its own socket — the same interface
/// an SSH pane gets. Nothing to deploy and nothing to reconnect.
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

  /// How `serve` is started. Injectable so a test does not start a real daemon
  /// on the developer's own socket and take their sessions with it.
  final Future<Process> Function(String path)? startServe;

  /// How long the handshake is given before the answer is called missing.
  final Duration helloBound;

  final AppLogger _logger;

  Future<HostDeployment>? _reading;
  HostDeployment? _last;

  /// The last reading taken, or null when nobody has looked. Null is *unknown*
  /// and never a negative answer (§19).
  HostDeployment? get lastReading => _last;

  @override
  String get address => 'this machine';

  /// Never fires: a local socket has no reconnect to hang on, and an empty
  /// stream is the honest way to say so.
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

  /// Forgets the reading, so the next pane measures again. Called when a dial
  /// fails: a remembered `ready` would send every later pane at a socket
  /// nothing is listening on.
  void forget() => _reading = null;

  /// Looks, and starts nothing: reading Settings with the setting off must not
  /// launch a daemon. `unknown` when nothing answers.
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

  /// Always false, and it is an observation rather than a stub: nothing on this
  /// machine's pane path has ever gone through tmux, so there is no session
  /// here that could be taken away from one.
  @override
  Future<bool?> hasTmuxSession(String name) async => false;

  /// Null, and never asked: a local host pane is handed a `PtyLaunch` built
  /// from the terminal profile, so it never falls back to a default shell.
  @override
  Future<String?> loginShell() async => null;

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
      // A refused connection means nobody is there; a handshake that ran out of
      // bound means a busy machine, and must not start a second daemon.
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

  /// Opens a link, reads the welcome, and hangs up. The same `HostPaneLink` a
  /// pane uses, so there is no second handshake to drift.
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
      // Three different answers, and only one means the socket is empty: a host
      // that speaks another protocol and one that said nothing inside the bound
      // both mean a host IS there, and a second must not be started over it.
      if (e.timedOut) return _NoAnswer(e.message);
      return e.message.contains('protocol') ? _Mismatched(e.message) : const _Silent();
    }
  }

  /// Starts `serve`, detached, and waits for it to say where it bound — the
  /// daemon prints one line when the socket is up, and that line is the event.
  /// Returns null on success, or the sentence to refuse with.
  Future<String?> _start(File binary) async {
    final Process process;
    try {
      process =
          await (startServe?.call(binary.path) ??
              Process.start(
                binary.path,
                const ['serve'],
                // Detached, so it outlives this app — which is the entire
                // point — but with stdio, so the banner is readable.
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

/// Where `karmashala_host` is on this machine, asked every time: a stored path
/// is state and whether it resolves is a measurement (§20).
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

/// A [RemoteChannel] over a plain socket — the frames are identical to the ones
/// an SSH exec channel carries, which is what makes `attach` a byte proxy.
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

/// Something took the connection and did not finish the handshake in time — a
/// *reading* of how busy the machine was, never an event about a host.
class _NoAnswer extends _HelloOutcome {
  const _NoAnswer(this.reason);
  final String reason;
}

class _Mismatched extends _HelloOutcome {
  const _Mismatched(this.reason);
  final String reason;
}
