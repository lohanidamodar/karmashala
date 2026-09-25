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
    this.serveEnvironment,
    this.stopServe,
    this.dataDirectory,
    this.serveFlags = const [],
  }) : _paths = paths ?? HostPaths.resolve(),
       _logger = logger ?? AppLogger.named('host.local');

  /// How a running host is stopped: null when it went, else the sentence to
  /// refuse with. Injectable for the same reason as [startServe]. Without
  /// [force] the host's own `stop` refuses while a session is running.
  final Future<String?> Function(String path, {required bool force})? stopServe;

  final HostPaths _paths;

  /// Where to look for the binary. Injectable because a test cannot put an
  /// executable beside the test runner.
  final LocalHostExecutable executable;

  /// How `serve` is started. Injectable so a test does not start a real daemon
  /// on the developer's own socket and take their sessions with it.
  final Future<Process> Function(String path)? startServe;

  /// How long the handshake is given before the answer is called missing.
  final Duration helloBound;

  /// Variables layered over this app's own for the `serve` it starts. A probe
  /// names its own host directory here, so the host it starts binds *its*
  /// socket and keeps *its* sessions — [HostPaths.resolve] reads the same name
  /// in `serve`, `attach` and `list`. Null for the real app: nothing changes.
  final Map<String, String>? serveEnvironment;

  /// The app's data directory, whose `karmashala.sqlite` the `serve` it starts
  /// opens as its store. Asked at start, since resolving it is async.
  final Future<String> Function()? dataDirectory;

  /// More `serve` flags: a probe's host asks for an ephemeral MCP port, so it
  /// never takes the real host's.
  final List<String> serveFlags;

  /// What `serve` is started with. Without [dataDirectory] it has no
  /// `--data-dir`, and `serve` refuses in words.
  Future<List<String>> serveArguments() async {
    final directory = await dataDirectory?.call();
    return [
      'serve',
      if (directory != null) '--data-dir=$directory',
      ...serveFlags,
    ];
  }

  /// Where this access looks for its host — its socket, lock and sessions.
  HostPaths get paths => _paths;

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
        // An outdated host is asked again too: once its sessions end, the next
        // pane is the moment to replace it.
        if (reading.status == HostDeploymentStatus.unknown ||
            reading.hostOutdated) {
          _reading = null;
        }
        return _last = reading;
      });

  /// Forgets the reading, so the next pane measures again. Called when a dial
  /// fails: a remembered `ready` would send every later pane at a socket
  /// nothing is listening on.
  void forget() => _reading = null;

  /// Whether a pane whose host session is [sessionId] belongs in this host.
  /// False only for a new pane when the last reading found an outdated host:
  /// that pane runs in the app instead, and a pane with a session there still
  /// reattaches to it.
  bool acceptsPane(String sessionId) {
    final last = _last;
    if (last == null || !last.hostOutdated) return true;
    final live = last.liveSessionIds;
    // Holding nothing, it is replaced by the pane that asks next.
    if (live != null && (live.isEmpty || live.contains(sessionId))) {
      return true;
    }
    // Looked at again, starting nothing, so the pane after this one goes back
    // to the host once those sessions have ended.
    unawaited(observe().catchError((Object _) => last));
    return false;
  }

  /// Stops whatever host is running — [force] takes its sessions with it —
  /// and starts this app's own. Only on an explicit request from the person.
  Future<HostDeployment> restartHost({required bool force}) async {
    final binary = executable.locate();
    if (binary == null) return deployment();
    final refused = await _stop(binary, force: force);
    forget();
    if (refused != null) {
      final now = DateTime.now();
      return _last = HostDeployment(
        status: HostDeploymentStatus.cannotStart,
        observedAt: now,
        reason: 'Could not stop the running session host: $refused',
        platform: _platform(now),
        remotePath: binary.path,
      );
    }
    return deployment();
  }

  /// Looks, and starts nothing: reading Settings with the setting off must not
  /// launch a daemon. `unknown` when nothing answers.
  Future<HostDeployment> observe() async {
    final binary = executable.locate();
    final answered = await _sayHello();
    final now = DateTime.now();
    if (answered case _Welcomed(:final welcome)) {
      final restartedByUs = _last?.restartedByUs ?? false;
      // Kept, unlike a reading nobody could take: whether the host is outdated
      // is what decides where the next pane goes.
      return _last = _isCurrent(welcome, binary)
          ? _ready(welcome, binary?.path ?? '', restartedByUs: restartedByUs)
          : _outdated(welcome, binary!.path, await liveSessionIds());
    }
    // The outdated host is gone, so what it held no longer decides anything.
    if (_last?.hostOutdated ?? false) _last = null;
    return switch (answered) {
      _Welcomed() => throw StateError('handled above'),
      _Mismatched(:final reason) => HostDeployment(
        status: HostDeploymentStatus.protocolMismatch,
        observedAt: now,
        reason: reason,
        remotePath: binary?.path,
      ),
      _NoAnswer(:final reason) => HostDeployment(
        status: HostDeploymentStatus.unknown,
        observedAt: now,
        reason:
            'Could not finish the handshake on ${_paths.socketPath}: $reason',
        remotePath: binary?.path,
        hostUnresponsive: true,
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
        reason:
            'Nothing is listening on ${_paths.socketPath}; no host is running here.',
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
      return _isCurrent(answered.welcome, binary)
          ? _ready(answered.welcome, binary.path, restartedByUs: false)
          : _replaceOutdated(answered.welcome, binary);
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
            '${answered.reason} A host holds that socket, so no second one was '
            'started over it. If it stays silent, restart it in Settings → '
            'Shell integration & session host.',
        platform: _platform(now),
        remotePath: binary.path,
        hostUnresponsive: true,
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

  /// Whether [welcome] came from the build this app would start. A binary that
  /// cannot be read is no evidence either way, so it counts as current.
  bool _isCurrent(WelcomeMessage welcome, File? binary) {
    final expected = binary == null ? null : hostBuildOf(binary.path);
    return expected == null || welcome.build == expected;
  }

  /// An older host is replaced only when it holds nothing running; `stop`
  /// without `--force` checks again, so a session opened meanwhile survives.
  Future<HostDeployment> _replaceOutdated(
    WelcomeMessage welcome,
    File binary,
  ) async {
    final live = await liveSessionIds();
    if (live == null || live.isNotEmpty) {
      return _outdated(welcome, binary.path, live);
    }
    final refused = await _stop(binary, force: false);
    if (refused != null) {
      return _outdated(welcome, binary.path, live, stopRefused: refused);
    }
    final started = await _start(binary);
    final fresh = started == null ? await _sayHello() : null;
    if (fresh is _Welcomed) {
      final ready = _ready(fresh.welcome, binary.path, restartedByUs: true);
      return HostDeployment(
        status: ready.status,
        observedAt: ready.observedAt,
        reason:
            'Replaced an older session host, which held no running sessions, '
            'with the one this app ships.',
        platform: ready.platform,
        remotePath: ready.remotePath,
        hostVersion: ready.hostVersion,
        protocolVersion: ready.protocolVersion,
        restartedByUs: true,
      );
    }
    final now = DateTime.now();
    return HostDeployment(
      status: HostDeploymentStatus.cannotStart,
      observedAt: now,
      reason:
          'Stopped an older session host that held no running sessions, but '
          '${started ?? 'nothing answered on ${_paths.socketPath} after starting ${binary.path}'}.',
      platform: _platform(now),
      remotePath: binary.path,
    );
  }

  HostDeployment _outdated(
    WelcomeMessage welcome,
    String path,
    List<String>? live, {
    String? stopRefused,
  }) {
    final holds = live == null
        ? 'It would not say what it holds'
        : 'It holds ${live.length} running session(s)';
    return HostDeployment(
      status: HostDeploymentStatus.ready,
      observedAt: DateTime.now(),
      reason:
          'An older session host, started by an earlier Karmashala, is running '
          'here. $holds, so it was left running: they keep working, and new '
          'terminals run inside the app until it is restarted.'
          '${stopRefused == null ? '' : ' Stopping it was refused: $stopRefused'}',
      platform: HostPlatform(
        operatingSystem: welcome.operatingSystem,
        architecture: welcome.architecture,
        libc: HostLibc.unknown,
        observedAt: welcome.observedAt,
      ),
      remotePath: path,
      hostVersion: welcome.hostVersion,
      protocolVersion: welcome.protocolVersion,
      hostOutdated: true,
      liveSessionIds: live,
    );
  }

  /// The running sessions' ids, or null when the host would not say.
  Future<List<String>?> liveSessionIds() async {
    try {
      return [
        for (final session in await listSessions())
          if (!session.lifecycle.hasEnded) session.id,
      ];
    } on Object catch (e) {
      _logger.debug('local host would not list its sessions: $e');
      return null;
    }
  }

  /// Every session the host holds, running or kept after it ended. Throws
  /// when no host answers.
  Future<List<SessionSummary>> listSessions() =>
      _withLink((link) => link.listSessions());

  /// Ends one session on the host for good.
  Future<void> endSession(String sessionId) =>
      _withLink((link) => link.closeSession(sessionId));

  Future<T> _withLink<T>(Future<T> Function(HostPaneLink link) use) async {
    final channel = SocketRemoteChannel(await _connect());
    HostPaneLink? link;
    try {
      link = await HostPaneLink.open(
        channel,
        clientId: 'karmashala-sessions',
        bound: helloBound,
      );
      return await use(link);
    } finally {
      await link?.close();
      await channel.close();
    }
  }

  /// `stop` from this app's own binary, pointed at [paths]: it ends the host
  /// there, whatever build that host is.
  Future<String?> _stop(File binary, {required bool force}) async {
    final custom = stopServe;
    if (custom != null) return custom(binary.path, force: force);
    try {
      final result = await Process.run(
        binary.path,
        ['stop', if (force) '--force'],
        environment: {
          ...?serveEnvironment,
          // This access's own directory, named rather than re-resolved: `stop`
          // must end the host this access measured and no other.
          kHostDirectoryEnvironmentVariable: _paths.directory.path,
        },
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode == 0) return null;
      final said = '${result.stderr}'.trim();
      return said.isEmpty ? 'stop exited ${result.exitCode}' : said;
    } on ProcessException catch (e) {
      return 'could not run ${binary.path} stop: ${e.message}';
    } on TimeoutException {
      return '${binary.path} stop did not finish within 20s';
    }
  }

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
      return e.message.contains('protocol')
          ? _Mismatched(e.message)
          : const _Silent();
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
                await serveArguments(),
                environment: serveEnvironment,
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

    // How a serve that died is noticed. NOT `process.exitCode`: a
    // `detachedWithStdio` process has none, and the SDK throws "Process is
    // detached" for it — which it did on every cold start, after the host was
    // already up, so the first host-backed pane always refused itself. Both
    // pipes closing before the banner is the same event, spelled the way a
    // detached process can report it.
    var open = 2;
    void closed() {
      if (--open > 0 || ready.isCompleted) return;
      final text = said.toString().trim();
      // "Another host is already running" (serve's exit 3) means one is up
      // after all — a race with another app instance, not a failure to report.
      ready.complete(
        text.contains('another host is already running')
            ? null
            : 'Started ${binary.path} and it exited before serving: $text',
      );
    }

    process.stdout
        .transform(utf8.decoder)
        .listen(look, onError: (Object _) {}, onDone: closed);
    process.stderr
        .transform(utf8.decoder)
        .listen(look, onError: (Object _) {}, onDone: closed);

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

  /// Lazy on purpose: the last-but-one entry lists a directory, and an
  /// installed app matches the first and never pays for it.
  Iterable<String> _candidates() sync* {
    final beside =
        executableDirectory ?? File(Platform.resolvedExecutable).parent.path;
    final root = repositoryRoot ?? Directory.current.path;
    // The bundle `dart build cli` writes: the executable finds its SQLite at
    // `../lib`, so it cannot be flattened into the app's own directory.
    yield '$beside/host/bin/$fileName';
    // A debug run, whichever target was built into the package.
    for (final directory in _builtBundles(root)) {
      yield '$directory/$fileName';
    }
    // Last: an install from before the host carried a store, left behind by an
    // in-place upgrade — the installer deletes nothing. It still serves panes,
    // which is all the local host is asked for today, but it cannot hold a
    // store, so anything that can is preferred to it.
    yield '$beside/$fileName';
  }

  /// `packages/host/build/cli/<os>_<arch>/bundle/bin`, listed rather than spelled:
  /// the target directory's name is the building machine's, not ours to predict.
  static Iterable<String> _builtBundles(String root) sync* {
    final built = Directory('$root/packages/host/build/cli');
    if (!built.existsSync()) return;
    for (final target in built.listSync().whereType<Directory>()) {
      yield '${target.path}/bundle/bin';
    }
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
