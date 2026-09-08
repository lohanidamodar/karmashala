import 'dart:io';

/// Where the socket and the lock live, and why.
///
/// `$XDG_RUNTIME_DIR` first because it is per-user, mode 0700, on tmpfs, and
/// cleaned when the user's last session ends — exactly the lifetime a socket
/// wants. `~/.karmashala` second because plenty of SSH hosts have no runtime
/// dir for a non-login session, and a host that refuses to start there would
/// be a host that does not start at all.
class HostPaths {
  HostPaths(this.directory);

  final Directory directory;

  static HostPaths resolve({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final runtimeDir = env['XDG_RUNTIME_DIR'];
    if (runtimeDir != null && runtimeDir.isNotEmpty && Directory(runtimeDir).existsSync()) {
      return HostPaths(Directory('$runtimeDir/karmashala'));
    }
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    return HostPaths(Directory('$home/.karmashala'));
  }

  String get socketPath => '${directory.path}/host.sock';
  String get lockPath => '${directory.path}/host.lock';
  String get logPath => '${directory.path}/host.log';
  String get binDirectory => '${directory.path}/bin';

  void ensureDirectory() {
    if (!directory.existsSync()) directory.createSync(recursive: true);
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
