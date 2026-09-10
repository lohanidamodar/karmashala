import 'dart:io';

import 'package:karmashala_core/logging.dart';

/// Restricts [file] so no other user on the machine can read it.
///
/// `mcp_bridge.json` holds two bearer tokens in cleartext and every local
/// process can reach loopback, so this file's permissions are the boundary
/// behind the boundary. On a stock Windows 11 profile the inherited DACL is
/// already user-only — but *inherited* (`AreAccessRulesProtected: False`): a
/// broader ACE on any ancestor propagates down, and `writeAsString` preserves
/// whatever DACL a file already carries. So this grants an explicit ACE and
/// **strips inheritance**, keeping SYSTEM and Administrators, since an admin can
/// take ownership anyway and excluding them only breaks backup tooling.
///
/// Returns whether it was applied. A `false` is a refusal: the privileged token
/// is never written, and the transport it authenticates comes down.
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

/// Restricts the directory [dir] so no other user on the machine can enter it —
/// the boundary for the RPC **socket**, which carries none of its own, since
/// anyone who can traverse to a unix socket can reach it. The Windows grant is
/// `(OI)(CI)` so the socket node created inside is covered. Returns whether it
/// was applied; a `false` means the boundary is absent, not weakened, so no
/// socket is created at all.
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
  // file the flags are meaningless, so they are only added where they mean
  // something.
  final flags = inheritToChildren ? '(OI)(CI)(F)' : '(F)';

  // Grant *first*, strip inheritance *second*. `/inheritance:r` deletes
  // inherited ACEs outright rather than converting them to explicit ones, so
  // stripping before granting would leave an entity its own owner cannot open.
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

/// `DOMAIN\user` for the current account, or just `user`, or `null` when the
/// environment does not say. For a local account `USERDOMAIN` is the machine
/// name, which is what `whoami` prints and what LSA resolves.
String? _currentWindowsPrincipal() {
  final env = Platform.environment;
  final user = env['USERNAME'];
  if (user == null || user.isEmpty) return null;
  final domain = env['USERDOMAIN'];
  return (domain == null || domain.isEmpty) ? user : '$domain\\$user';
}

/// The two permission operations [restrictHandshakeFileToCurrentUser] and
/// [restrictDirectoryToCurrentUser] provide, behind a seam. `icacls` and
/// `chmod` cannot be made to fail on demand, and "what happens when hardening
/// fails" is the entire security contract of the privileged RPC transport.
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
