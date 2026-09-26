import 'dart:io';

import 'package:karmashala_local_ipc/socket_location.dart';

/// Names the host's directory — socket, lock, log and sessions — in place of
/// the per-user default. The store is not here: it is the app's, named by
/// `serve --data-dir`. Set by a probe of the desktop app when it starts its own
/// `serve`, so the probe's host never meets the owner's (§23).
const String kHostDirectoryEnvironmentVariable = 'KARMASHALA_HOST_DIR';

/// [kHostDirectoryEnvironmentVariable] when it is set, else
/// `$XDG_RUNTIME_DIR` — per-user, 0700, tmpfs — then `~/.karmashala`,
/// because plenty of SSH hosts have no runtime dir for a non-login session.
/// Windows roots at `%USERPROFILE%`: a stray inherited `HOME` must not move it.
class HostPaths {
  HostPaths(this.directory);

  final Directory directory;

  static HostPaths resolve({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final scoped = env[kHostDirectoryEnvironmentVariable]?.trim();
    if (scoped != null && scoped.isNotEmpty) {
      return HostPaths(Directory(scoped));
    }
    if (!Platform.isWindows) {
      final runtimeDir = env['XDG_RUNTIME_DIR'];
      if (runtimeDir != null &&
          runtimeDir.isNotEmpty &&
          Directory(runtimeDir).existsSync()) {
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
  ///
  /// [preferredSocketPath] unless that is too long for this system to bind — a
  /// long or non-Latin home directory — in which case a short private per-user
  /// one. Both the app and `serve` read it here, so they always agree.
  String get socketPath => socketLocation.path ?? preferredSocketPath;

  /// Where the socket goes, and why, for `serve` to prepare or refuse.
  SocketLocation get socketLocation => locateSocket(preferredSocketPath);

  String get preferredSocketPath => '${directory.path}/host.sock';
  String get lockPath => '${directory.path}/host.lock';

  /// The data directory of the server holding [lockPath], written beside it
  /// (the lock itself stays a bare pid: shell scripts read it). What a second
  /// server started as the same user is refused with.
  String get holderDataDirectoryPath => '${directory.path}/host.data-dir';
  String get logPath => '${directory.path}/host.log';
  String get binDirectory => '${directory.path}/bin';

  /// Where agent hooks are taken and with which token; kept across restarts so
  /// hooks keep reaching a host restarted with the app closed.
  String get hookEndpointPath => '${directory.path}/hook.endpoint';

  /// The MCP endpoint's secrets and last port — the caller key every session
  /// token is derived from — kept so tokens outlive a restart of either side.
  String get mcpCredentialsPath => '${directory.path}/mcp.credentials';

  /// The last tool catalogue an app sent, served while no app is connected.
  String get mcpToolsPath => '${directory.path}/mcp_tools.json';

  /// The bridge's owner-only `/rpc` socket, before [locateSocket] moves it.
  String get preferredMcpSocketPath => '${directory.path}/mcp.sock';

  /// Each session's output and metadata, inside the same owner-only directory
  /// as the socket — scrollback is as sensitive as the channel carrying it.
  /// Shared by every server this user runs here in turn; each record names
  /// the data directory of the server it belongs to (`SessionStore.owner`).
  String get sessionsDirectory => '${directory.path}/sessions';

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
    final principal = (domain == null || domain.isEmpty)
        ? user
        : '$domain\\$user';
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
    final stripped = await Process.run('icacls', [
      directory.path,
      '/inheritance:r',
    ]);
    if (stripped.exitCode != 0) {
      return 'icacls /inheritance:r on ${directory.path} failed: ${stripped.stderr}';
    }
    return null;
  }
}

/// One instance per user, held by an OS file lock rather than a pid file: a pid
/// lies after a reboot or a wrap, and a lock is released however the holder dies.
class HostLock {
  HostLock._(this._file, this.path, this._notePath);

  final RandomAccessFile _file;
  final String path;
  final String? _notePath;

  /// Null when another instance holds it, so no second host binds over its
  /// socket. With [dataDirectory], the holder's data directory is written to
  /// [notePath] for [describeHolder] to name.
  static HostLock? tryAcquire(
    String path, {
    String? notePath,
    String? dataDirectory,
  }) {
    // Opened without truncating: a refused attempt must leave the holder's
    // pid readable, for this refusal, `stop` and the deployer's scripts.
    final file = File(path).openSync(mode: FileMode.append);
    try {
      file.lockSync(FileLock.exclusive);
    } on FileSystemException {
      file.closeSync();
      return null;
    }
    file
      ..truncateSync(0)
      ..setPositionSync(0)
      ..writeStringSync('$pid\n')
      ..flushSync();
    if (notePath != null) {
      try {
        if (dataDirectory == null) {
          if (File(notePath).existsSync()) File(notePath).deleteSync();
        } else {
          File(notePath).writeAsStringSync('$dataDirectory\n', flush: true);
        }
      } on FileSystemException {
        // Only ever read for a refusal's wording.
      }
    }
    return HostLock._(file, path, notePath);
  }

  /// Best effort, for a refusal message that names something. Never trusted.
  static String describeHolder(String path, {String? notePath}) {
    String? holder;
    try {
      final text = File(path).readAsStringSync().trim();
      if (text.isNotEmpty) holder = 'pid $text';
    } on FileSystemException {
      // Unnamed.
    }
    String? data;
    if (notePath != null) {
      try {
        final text = File(notePath).readAsStringSync().trim();
        if (text.isNotEmpty) data = 'data in $text';
      } on FileSystemException {
        // An older host, or one that could not write it.
      }
    }
    final parts = [?holder, ?data];
    return parts.isEmpty ? 'an unnamed process' : parts.join(', ');
  }

  void release() {
    final note = _notePath;
    if (note != null) {
      try {
        File(note).deleteSync();
      } on FileSystemException {
        // Never written, or already gone.
      }
    }
    try {
      _file
        ..unlockSync()
        ..closeSync();
    } on FileSystemException {
      // Already gone; the OS released it when we did.
    }
  }
}
