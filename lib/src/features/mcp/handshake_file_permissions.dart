import 'dart:io';

import 'package:karmashala_core/logging.dart';

/// Restricts [file] so no other user can read the two bearer tokens in it: an
/// explicit ACE and **stripped inheritance**, and a `false` is a refusal.
Future<bool> restrictHandshakeFileToCurrentUser(
  File file, {
  AppLogger? logger,
}) async {
  try {
    if (Platform.isWindows) return await _restrictWindows(file, logger);
    // POSIX: the same boundary, spelled the way dray spells it.
    final result = await Process.run('chmod', ['600', file.path]);
    if (result.exitCode != 0) {
      logger?.warning('chmod 600 on ${file.path} failed: ${result.stderr}');
      return false;
    }
    return true;
  } catch (error) {
    logger?.warning('Could not restrict ${file.path}: $error');
    return false;
  }
}

/// Restricts the directory [dir] — the whole boundary for the RPC socket, which
/// carries none of its own. A `false` means no socket is created at all.
Future<bool> restrictDirectoryToCurrentUser(
  Directory dir, {
  AppLogger? logger,
}) async {
  try {
    if (Platform.isWindows) {
      return await _restrictWindows(dir, logger, inheritToChildren: true);
    }
    final result = await Process.run('chmod', ['700', dir.path]);
    if (result.exitCode != 0) {
      logger?.warning('chmod 700 on ${dir.path} failed: ${result.stderr}');
      return false;
    }
    return true;
  } catch (error) {
    logger?.warning('Could not restrict ${dir.path}: $error');
    return false;
  }
}

Future<bool> _restrictWindows(
  FileSystemEntity entity,
  AppLogger? logger, {
  bool inheritToChildren = false,
}) async {
  final principal = _currentWindowsPrincipal();
  if (principal == null) {
    logger?.warning(
      'USERNAME is not set; leaving ${entity.path} on its inherited ACL.',
    );
    return false;
  }

  // `(OI)(CI)` makes the ACE apply to what is created inside a directory; on a
  // file the flags are meaningless.
  final flags = inheritToChildren ? '(OI)(CI)(F)' : '(F)';

  // Grant *first*, strip inheritance *second*: `/inheritance:r` deletes
  // inherited ACEs, so the other order leaves an entity its owner cannot open.
  final granted = await Process.run('icacls', [
    entity.path,
    '/grant:r',
    // Well-known SIDs, not names: `Administrators` is localised, `S-1-5-32-544`
    // is not.
    '*S-1-5-18:$flags', // NT AUTHORITY\SYSTEM
    '*S-1-5-32-544:$flags', // BUILTIN\Administrators
    '$principal:$flags',
  ]);
  if (granted.exitCode != 0) {
    logger?.warning(
      'icacls /grant on ${entity.path} failed: ${granted.stderr}',
    );
    return false;
  }

  final stripped = await Process.run('icacls', [entity.path, '/inheritance:r']);
  if (stripped.exitCode != 0) {
    logger?.warning(
      'icacls /inheritance:r on ${entity.path} failed: ${stripped.stderr}',
    );
    return false;
  }
  return true;
}

/// `DOMAIN\user` for the current account, or just `user`, or `null`. For a local
/// account `USERDOMAIN` is the machine name, which is what LSA resolves.
String? _currentWindowsPrincipal() {
  final env = Platform.environment;
  final user = env['USERNAME'];
  if (user == null || user.isEmpty) return null;
  final domain = env['USERDOMAIN'];
  return (domain == null || domain.isEmpty) ? user : '$domain\\$user';
}

/// The two permission operations behind a seam: `icacls` and `chmod` cannot be
/// made to fail on demand, and the fail-closed path has to be testable.
abstract class HandshakePermissions {
  const HandshakePermissions();

  /// Restricts [file] to the current user. Returns whether it was applied.
  Future<bool> restrictFile(File file, {AppLogger? logger});

  /// Restricts [dir] to the current user. Returns whether it was applied.
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger});
}

/// The real thing: the platform ACL tools.
class SystemHandshakePermissions extends HandshakePermissions {
  const SystemHandshakePermissions();

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) =>
      restrictHandshakeFileToCurrentUser(file, logger: logger);

  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) =>
      restrictDirectoryToCurrentUser(dir, logger: logger);
}
