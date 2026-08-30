import 'dart:io';

import '../../core/logging/app_logger.dart';

/// Restricts [file] so no other user on the machine can read it.
///
/// `mcp_bridge.json` holds two bearer tokens in cleartext. Loopback TCP is
/// reachable by **every** local process (see `LauncherControlServer`'s threat
/// model), so those tokens are the whole access-control boundary — which makes
/// the permissions on the file that publishes them the boundary behind the
/// boundary. dray gets this for free by putting a unix socket in a `0700`
/// directory; on Windows there is no equivalent default to lean on, so we assert
/// it.
///
/// ## What was already true, and why this is still worth doing
///
/// Audited on a stock Windows 11 profile, the file's DACL is inherited from
/// `%APPDATA%` and grants exactly `SYSTEM`, `BUILTIN\Administrators` and the
/// owning user — no `Users`, `Authenticated Users` or `Everyone` ACE. So on a
/// default profile another non-admin user already could not read it.
///
/// The problem is that this was *inherited*, never asserted: `Get-Acl` reported
/// `AreAccessRulesProtected: False`. A broader ACE added to `%APPDATA%` or any
/// ancestor — by a domain policy, a roaming-profile setup, a folder-redirection
/// GPO, or a user who once loosened a parent folder — propagates straight down
/// to the token file, silently. And `writeAsString` over an existing file
/// preserves whatever DACL that file already carries, so a file created under a
/// loose parent stays loose forever after.
///
/// This function removes that dependency: it grants an explicit ACE to the
/// current user (plus SYSTEM and Administrators) and then **strips inheritance**,
/// so the file's permissions no longer track its ancestors.
///
/// SYSTEM and Administrators are kept deliberately. An administrator can take
/// ownership of any file on the machine, so excluding them buys nothing against
/// the actual threat — another *non-admin* local user — while breaking backup,
/// anti-malware and management tooling. The boundary this establishes is "no
/// unprivileged account other than the owner", which is exactly what a `0700`
/// directory gives dray.
///
/// Returns whether the restriction was applied. A `false` is logged and
/// otherwise tolerated: the file keeps its inherited ACL, which on a default
/// profile is still user-only. Failing to start the control server over this
/// would be worse than the risk it mitigates.
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

/// Restricts the directory [dir] so no other user on the machine can enter it.
///
/// This is the boundary for the local RPC **socket**, which carries no
/// permissions of its own: a unix domain socket is reachable by anyone who can
/// traverse to it, so "who may call the app's privileged RPC" is decided here
/// and nowhere else. It is the same `0700` model dray uses, asserted rather
/// than inherited for exactly the reasons [restrictHandshakeFileToCurrentUser]
/// documents.
///
/// The Windows grant is `(OI)(CI)` — object- and container-inherit — so the
/// socket node created inside the directory is covered too, rather than
/// depending on whatever the socket file is born with.
///
/// Returns whether the restriction was applied.
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

  // `(OI)(CI)` makes the ACE apply to what is created inside a directory. On a
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
