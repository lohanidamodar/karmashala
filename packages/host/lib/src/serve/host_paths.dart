import 'dart:io';

/// `$XDG_RUNTIME_DIR` first — per-user, 0700, tmpfs — then `~/.karmashala`,
/// because plenty of SSH hosts have no runtime dir for a non-login session.
/// Windows roots at `%USERPROFILE%`: a stray inherited `HOME` must not move it.
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

  /// A unix domain socket on Windows as well as POSIX: `AF_UNIX` has worked
  /// since 10 1803, so the local stage needs no second listener.
  String get socketPath => '${directory.path}/host.sock';
  String get lockPath => '${directory.path}/host.lock';
  String get logPath => '${directory.path}/host.log';
  String get binDirectory => '${directory.path}/bin';

  /// Each session's output and metadata, inside the same owner-only directory
  /// as the socket — scrollback is as sensitive as the channel carrying it.
  String get sessionsDirectory => '${directory.path}/sessions';

  /// Where the store lives: this host's own pairings, and the schema it shares
  /// with the desktop. A directory rather than a file, because `AppDatabase`
  /// names the file inside one.
  Directory get storeDirectory => directory;

  void ensureDirectory() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
  }

  /// Makes [directory] unreachable by any other account: the whole access
  /// control on a socket that carries none of its own, so `serve` refuses to
  /// bind without it. Returns null on success, or the sentence to refuse with.
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
    // Well-known SIDs, not localised names. Grant first and strip inheritance
    // second: `/inheritance:r` deletes inherited ACEs rather than converting
    // them, so the other order locks the owner out of their own directory.
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

/// One instance per user, held by an OS file lock rather than a pid file: a pid
/// lies after a reboot or a wrap, and a lock is released however the holder dies.
class HostLock {
  HostLock._(this._file, this.path);

  final RandomAccessFile _file;
  final String path;

  /// Null when another instance holds it, so no second host binds over its
  /// socket.
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

  /// Best effort, for a refusal message that names something. Never trusted.
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
