/// Where a unix domain socket can actually be bound, which is not always where
/// its owner would put it.
///
/// The kernel copies a socket's path into a fixed `sun_path` buffer, so a path
/// longer than that cannot be bound at all. Measured on macOS 26, 2026-09-16:
/// 103 bytes bind and 104 are refused with "The length of path exceeds the
/// limit". A debug run with its data directory inside the repository put the
/// app's RPC socket at 125 bytes, and the app then withheld every privileged
/// tool from the agents in it — the handshake carried no socket, no token and no
/// MCP URL, and one log line said why.
///
/// So a socket stays where its owner put it whenever that fits — every default
/// install measured does — and moves to a short, private, per-user directory
/// only when it does not. Clients find a socket through the handshake that names
/// it, never by rebuilding its path, so a moved socket asks nothing of them.
library;

import 'dart:convert';
import 'dart:io';

/// The longest socket path [operatingSystem] binds, in UTF-8 **bytes**: a
/// Devanagari letter in a username costs three.
int maxSocketPathBytes(String operatingSystem) => switch (operatingSystem) {
  // Measured: 103 binds, 104 is refused. `sun_path` is 104 with its NUL.
  'macos' || 'ios' => 103,
  // `sun_path` is 108 with its NUL, on Linux and in Windows' AF_UNIX alike.
  'linux' || 'android' || 'windows' => 107,
  // Unknown: the smaller buffer is the one that is always safe.
  _ => 103,
};

/// Where a socket meant for one path can be bound.
sealed class SocketLocation {
  const SocketLocation();

  /// The path to bind and publish, or null when there is none.
  String? get path;
}

/// The path its owner chose, which fits.
final class PreferredSocketLocation extends SocketLocation {
  const PreferredSocketLocation(this.path);

  @override
  final String path;
}

/// A short private directory instead, because the chosen path did not fit.
final class FallbackSocketLocation extends SocketLocation {
  const FallbackSocketLocation({
    required this.path,
    required this.directory,
    required this.preferred,
    required this.preferredBytes,
    required this.limit,
    required this.sharedParent,
  });

  @override
  final String path;

  /// The directory holding [path]; its privacy is the socket's only boundary.
  final String directory;
  final String preferred;
  final int preferredBytes;
  final int limit;

  /// Whether [directory] sits in a parent other accounts can write to — `/tmp`
  /// — so that nobody else created it first is something to check, not assume.
  final bool sharedParent;

  /// One sentence for a log: what moved, and why.
  String get reason =>
      '$preferred is $preferredBytes bytes and this system binds at most '
      '$limit, so the socket is at $path';
}

/// Nowhere to bind: the chosen path does not fit, and neither does any short
/// private directory this machine offers.
final class UnplaceableSocket extends SocketLocation {
  const UnplaceableSocket(this.reason);

  final String reason;

  @override
  String? get path => null;
}

/// Where a socket meant for [preferred] can be bound on this machine.
///
/// [operatingSystem], [environment] and [currentUid] default to this process's;
/// they are parameters so every platform's answer is testable from any one.
SocketLocation locateSocket(
  String preferred, {
  String? operatingSystem,
  Map<String, String>? environment,
  int? Function()? currentUid,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  final limit = maxSocketPathBytes(os);
  final preferredBytes = _bytes(preferred);
  if (preferredBytes <= limit) return PreferredSocketLocation(preferred);

  final base = _fallbackDirectory(os, env, currentUid ?? posixUid);
  if (base == null) {
    return UnplaceableSocket(
      '$preferred is $preferredBytes bytes, more than the $limit this system '
      'binds, and this machine offers no short private directory to use '
      'instead. Use a shorter directory for it.',
    );
  }
  final separator = os == 'windows' ? r'\' : '/';
  final path = '${base.directory}$separator${socketFileNameFor(preferred)}';
  final bytes = _bytes(path);
  if (bytes > limit) {
    return UnplaceableSocket(
      '$preferred is $preferredBytes bytes, and even the short fallback $path '
      'is $bytes — this system binds at most $limit. Use a shorter directory '
      'for it.',
    );
  }
  return FallbackSocketLocation(
    path: path,
    directory: base.directory,
    preferred: preferred,
    preferredBytes: preferredBytes,
    limit: limit,
    sharedParent: base.shared,
  );
}

/// A file name that is short, the same every time for one [preferred] path and
/// different for another — so a debug run and the real app, each with its own
/// data directory, never share a socket.
///
/// FNV-1a, 64-bit, first 12 hex digits: this names a file inside a directory
/// that is already private, so it needs to be stable and distinct, not secret.
String socketFileNameFor(String preferred) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(preferred)) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  final high = (hash >>> 32).toRadixString(16).padLeft(8, '0');
  final low = (hash & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '${(high + low).substring(0, 12)}.sock';
}

/// The per-user directory a socket falls back to, or null where there is none.
({String directory, bool shared})? _fallbackDirectory(
  String os,
  Map<String, String> env,
  int? Function() uid,
) {
  String? absolute(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final isAbsolute = os == 'windows'
        ? RegExp(r'^([A-Za-z]:[\\/]|\\\\)').hasMatch(trimmed)
        : trimmed.startsWith('/');
    if (!isAbsolute) return null;
    return trimmed.replaceFirst(RegExp(r'[\\/]+$'), '');
  }

  switch (os) {
    case 'macos' || 'ios':
      // Per user and 0700 already: the system hands each account its own.
      final tmp = absolute(env['TMPDIR']);
      return tmp == null ? null : (directory: '$tmp/karmashala', shared: false);
    case 'linux' || 'android':
      // Per user, 0700 and on tmpfs, where a login session has one.
      final runtime = absolute(env['XDG_RUNTIME_DIR']);
      if (runtime != null) {
        return (directory: '$runtime/karmashala', shared: false);
      }
      // An SSH session often has none. `/tmp` is shared, which is why the
      // directory is named for the account and checked before it is trusted.
      final id = uid();
      return id == null
          ? null
          : (directory: '/tmp/karmashala-$id', shared: true);
    case 'windows':
      final local = absolute(env['LOCALAPPDATA']);
      return local == null
          ? null
          : (directory: '$local\\karmashala\\s', shared: false);
  }
  return null;
}

/// This account's uid on a POSIX machine, or null where it cannot be read.
int? posixUid() {
  if (Platform.isWindows) return null;
  try {
    final result = Process.runSync('id', ['-u']);
    if (result.exitCode != 0) return null;
    return int.tryParse('${result.stdout}'.trim());
  } on Object {
    return null;
  }
}

/// Creates [location]'s directory and proves it is private to this account.
/// Returns null on success, or the sentence to refuse with.
///
/// On POSIX the proof is the directory's own mode — and, in a shared parent,
/// that it is not a symlink and that this account owns it, because anyone can
/// create `/tmp/karmashala-<uid>` before we do. On Windows the caller's
/// owner-only ACL is the whole boundary, and this does not repeat it.
Future<String?> prepareFallbackSocketDirectory(
  FallbackSocketLocation location, {
  int? Function()? currentUid,
}) async {
  final dir = Directory(location.directory);
  try {
    if (Platform.isWindows) {
      await dir.create(recursive: true);
      return null;
    }

    if (location.sharedParent) {
      if (FileSystemEntity.isLinkSync(dir.path)) {
        return '${dir.path} is a symlink, so it cannot be trusted to hold a '
            'socket';
      }
      // Not recursive: the shared parent must already exist, and creating it
      // here would hide that something is badly wrong with this machine.
      if (!dir.existsSync()) await dir.create();
    } else {
      await dir.create(recursive: true);
    }

    final chmod = await Process.run('chmod', ['700', dir.path]);
    if (chmod.exitCode != 0) {
      return 'chmod 700 on ${dir.path} failed: ${chmod.stderr}'.trim();
    }
    final mode = dir.statSync().mode & 0x1ff;
    if (mode & 0x3f != 0) {
      return '${dir.path} is still readable by other accounts '
          '(mode ${mode.toRadixString(8)})';
    }

    if (location.sharedParent) {
      final owner = await _ownerUid(dir.path);
      final me = (currentUid ?? posixUid)();
      if (owner == null || me == null || owner != me) {
        return '${dir.path} belongs to uid $owner, not to this account '
            '(uid $me), so it cannot hold this account\'s socket';
      }
    }
    return null;
  } on Object catch (error) {
    return 'could not prepare ${dir.path}: $error';
  }
}

/// The uid owning [path], asked of `stat`: `dart:io` reports a mode but no owner.
Future<int?> _ownerUid(String path) async {
  final args = Platform.isMacOS ? ['-f', '%u', path] : ['-c', '%u', path];
  final result = await Process.run('stat', args);
  if (result.exitCode != 0) return null;
  return int.tryParse('${result.stdout}'.trim());
}

int _bytes(String value) => utf8.encode(value).length;
