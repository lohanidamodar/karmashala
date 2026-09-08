import 'dart:io';

/// Where the socket and the lock live, and why.
///
/// `$XDG_RUNTIME_DIR` first because it is per-user, mode 0700, on tmpfs, and
/// cleaned when the user's last session ends — exactly the lifetime a socket
/// wants. `~/.karmashala` second because plenty of SSH hosts have no runtime
/// dir for a non-login session, and a host that refuses to start there would
/// be a host that does not start at all.
///
/// On Windows the same second spelling is used, rooted at `%USERPROFILE%`
/// rather than `$HOME`: a Windows process can inherit a `HOME` from whatever
/// launched it, and the host's directory must not move because a tool set one.
class HostPaths {
  HostPaths(this.directory);

  final Directory directory;

  static HostPaths resolve({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    if (!Platform.isWindows) {
      final runtimeDir = env['XDG_RUNTIME_DIR'];
      if (runtimeDir != null && runtimeDir.isNotEmpty && Directory(runtimeDir).existsSync()) {
        return HostPaths(Directory('$runtimeDir/karmashala'));
      }
    }
    final home = Platform.isWindows
        ? (env['USERPROFILE'] ?? env['HOME'] ?? '.')
        : (env['HOME'] ?? env['USERPROFILE'] ?? '.');
    return HostPaths(Directory('$home/.karmashala'));
  }

  /// A unix domain socket, on Windows as well as POSIX.
  ///
  /// Windows has had `AF_UNIX` since 10 1803 and Dart's `ServerSocket` binds it
  /// there — measured on 2026-09-09, Windows 11 build 26200: bind, round trip
  /// and unlink on close all behave as they do on Linux. That is why the local
  /// stage adds no listener at all. The two alternatives were both refused with
  /// their reasons recorded:
  ///
  ///  * **A named pipe.** `packages/local_ipc/` *was* one and was deleted for a
  ///    measured defect this host would have inherited: the serving isolate
  ///    parks inside a blocking `ConnectNamedPipe`, a blocking FFI call cannot
  ///    be interrupted by `Isolate.kill` or by VM shutdown, and Loop 48 measured
  ///    the app failing to quit at all (>120 s) against 322 ms without it.
  ///  * **Loopback TCP with a per-launch secret.** `LauncherControlServer`'s own
  ///    threat model says why not: loopback carries no peer credentials, so any
  ///    local process of any user may connect and attempt auth, and the token
  ///    becomes the entire boundary. A socket inside a directory only this user
  ///    can traverse refuses that process before it can present anything.
  String get socketPath => '${directory.path}/host.sock';
  String get lockPath => '${directory.path}/host.lock';
  String get logPath => '${directory.path}/host.log';
  String get binDirectory => '${directory.path}/bin';

  void ensureDirectory() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
  }

  /// Makes [directory] unreachable by any other account on the machine.
  ///
  /// This is the whole access control on the socket, which carries none of its
  /// own: anybody who can traverse to the node can connect to it. Applied
  /// rather than inherited, for the reason the app's `restrictDirectoryToCurrentUser`
  /// documents — and asked for as a prerequisite, so a `serve` that could not
  /// establish the boundary does not bind at all.
  ///
  /// Returns null on success, or the sentence to refuse with.
  Future<String?> restrictToCurrentUser() async {
    try {
      if (Platform.isWindows) return await _restrictWindows();
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        return 'chmod 700 on ${directory.path} failed: ${result.stderr}';
      }
      return null;
    } on Object catch (e) {
      return 'could not restrict ${directory.path}: $e';
    }
  }

  Future<String?> _restrictWindows() async {
    final env = Platform.environment;
    final user = env['USERNAME'];
    if (user == null || user.isEmpty) {
      return 'USERNAME is not set, so the owner of ${directory.path} cannot be named';
    }
    final domain = env['USERDOMAIN'];
    final principal = (domain == null || domain.isEmpty) ? user : '$domain\\$user';
    // `(OI)(CI)` so the socket node created inside is covered too, and the
    // well-known SIDs rather than names, which are localised. Grant first and
    // strip inheritance second: `/inheritance:r` deletes inherited ACEs outright
    // rather than converting them, so the other order leaves a directory its own
    // owner cannot open.
    final granted = await Process.run('icacls', [
      directory.path,
      '/grant:r',
      '*S-1-5-18:(OI)(CI)(F)',
      '*S-1-5-32-544:(OI)(CI)(F)',
      '$principal:(OI)(CI)(F)',
    ]);
    if (granted.exitCode != 0) {
      return 'icacls /grant on ${directory.path} failed: ${granted.stderr}';
    }
    final stripped = await Process.run('icacls', [directory.path, '/inheritance:r']);
    if (stripped.exitCode != 0) {
      return 'icacls /inheritance:r on ${directory.path} failed: ${stripped.stderr}';
    }
    return null;
  }
}

/// One instance per user, enforced by an exclusive lock on a file rather than
/// by a pid written into one.
///
/// A pid file lies after a reboot or a pid wrap; an OS lock is released when
/// the holding process dies however it dies, which is the only property that
/// matters for a daemon nobody supervises.
class HostLock {
  HostLock._(this._file, this.path);

  final RandomAccessFile _file;
  final String path;

  /// Null when another instance holds it. The caller reports that rather than
  /// starting a second host that would bind over the first one's socket.
  static HostLock? tryAcquire(String path) {
    final file = File(path).openSync(mode: FileMode.write);
    try {
      file.lockSync(FileLock.exclusive);
    } on FileSystemException {
      file.closeSync();
      return null;
    }
    file
      ..writeStringSync('$pid\n')
      ..flushSync();
    return HostLock._(file, path);
  }

  /// Best effort: what the lock holder said its pid was, for a refusal message
  /// that names something. Never trusted for anything but words.
  static String describeHolder(String path) {
    try {
      final text = File(path).readAsStringSync().trim();
      return text.isEmpty ? 'an unnamed process' : 'pid $text';
    } on FileSystemException {
      return 'an unnamed process';
    }
  }

  void release() {
    try {
      _file
        ..unlockSync()
        ..closeSync();
    } on FileSystemException {
      // Already gone; the OS released it when we did.
    }
  }
}
