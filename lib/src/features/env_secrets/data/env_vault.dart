// The collaborators are named for callers (`directory:`, `cipher:`) but stored
// privately, which the initializing-formals lint cannot express: a named
// parameter may not start with an underscore, so `this._directory` — the fix it
// suggests — does not compile. Same reason, same ignore, as
// `secure_companion_store.dart`.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import '../../mcp/handshake_file_permissions.dart';
import '../domain/env_variable.dart';
import 'env_value_cipher.dart';

/// Raised when the vault refuses to store something rather than storing it
/// less well than promised.
class EnvVaultRefusal implements Exception {
  const EnvVaultRefusal(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The environment variables on disk: one JSON file, in a directory restricted
/// to this account.
///
/// **Why a file and not the database.** Three reasons, and none of them is
/// taste:
///
///  1. `karmashala.sqlite` carries no asserted ACL — it inherits whatever
///     `%APPDATA%` has. `restrictHandshakeFileToCurrentUser` documents at
///     length why inherited is not the same as applied.
///  2. SQLite does not erase deleted rows. Without `PRAGMA secure_delete` (off
///     by default here) a removed secret stays in freelist pages, and in the
///     `-wal` sidecar, indefinitely — "Remove" would not remove.
///  3. The database is the app's shareable state. A separate file with its own
///     ACL cannot be swept into an export by accident.
///
/// **What the permissions buy, and what they do not.** The same boundary the
/// MCP handshake file establishes: no *other* unprivileged account on this
/// machine can read it. A local administrator can, because an administrator can
/// take ownership of anything. And **any process running as this user can**,
/// because the app itself must read the values with no prompt in order to hand
/// them to a child process — there is no arrangement that gives a terminal its
/// variables and withholds them from everything else running as you.
class EnvVault {
  EnvVault({
    required Directory directory,
    EnvValueCipher cipher = const PlaintextEnvValueCipher(),
    HandshakePermissions permissions = const SystemHandshakePermissions(),
    AppLogger? logger,
  }) : _directory = directory,
       _cipher = cipher,
       _permissions = permissions,
       _logger = logger;

  /// A vault with nowhere to write: reports empty, stores nothing, refuses
  /// secrets.
  ///
  /// This is the **default** for `envVaultProvider`, and deliberately not a
  /// throwing stub the way `databaseProvider` is. An absent vault is a
  /// legitimate state — "no variables configured" — and the one thing this
  /// feature must never do is stop a terminal opening. A test that does not
  /// care about environment variables gets this and never notices the feature
  /// exists.
  EnvVault.unavailable()
    : _directory = null,
      _cipher = const PlaintextEnvValueCipher(),
      _permissions = const SystemHandshakePermissions(),
      _logger = null;

  final Directory? _directory;
  final EnvValueCipher _cipher;
  final HandshakePermissions _permissions;
  final AppLogger? _logger;

  EnvVaultData _data = EnvVaultData.empty;

  /// The last loaded or saved state. Never null; an unreadable vault is
  /// [EnvVaultData.unavailable], not an exception thrown at a caller who only
  /// wanted to open a shell.
  EnvVaultData get data => _data;

  /// The file name inside the restricted directory.
  static const String fileName = 'env.json';

  /// The directory the vault lives in, under application support.
  static const String directoryName = 'secrets';

  /// The real vault: `<application support>/secrets/env.json`, hardened.
  static Future<EnvVault> open({
    EnvValueCipher cipher = const PlaintextEnvValueCipher(),
    AppLogger? logger,
  }) async {
    final support = await getApplicationSupportDirectory();
    return EnvVault(
      directory: Directory(p.join(support.path, directoryName)),
      cipher: cipher,
      logger: logger,
    );
  }

  File get _file => File(p.join(_directory!.path, fileName));

  /// Creates and hardens the directory, then reads what is in it.
  ///
  /// Never throws. Every failure becomes an [EnvVaultData] that says what is
  /// wrong and injects nothing.
  Future<EnvVaultData> load() async {
    if (_directory == null) return _data = EnvVaultData.empty;
    var canStoreSecrets = false;
    try {
      await _directory.create(recursive: true);
      canStoreSecrets = await _permissions.restrictDirectory(
        _directory,
        logger: _logger,
      );
    } on Object catch (error) {
      _logger?.warning('Environment vault directory could not be prepared: $error');
      return _data = EnvVaultData.unavailable(
        'Karmashala could not create a protected folder for environment '
        'variables, so none are being loaded.',
      );
    }
    if (!canStoreSecrets) {
      // Not fatal for reading: a vault written when the ACL *was* applicable
      // must still be usable. It is fatal for writing a secret — see [save].
      _logger?.warning(
        'Environment vault folder could not be restricted to this account; '
        'secret variables cannot be saved.',
      );
    }

    final file = _file;
    if (!file.existsSync()) {
      return _data = EnvVaultData(canStoreSecrets: canStoreSecrets);
    }

    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      json = decoded;
    } on Object catch (error) {
      _logger?.warning('Environment vault could not be parsed: $error');
      return _data = EnvVaultData.unavailable(
        'The environment variables file could not be read, so none are being '
        'loaded. Nothing has been overwritten.',
        canStoreSecrets: canStoreSecrets,
      );
    }

    final storedCipher = '${json['enc']}';
    if (storedCipher != _cipher.id) {
      // Never guess. A vault encrypted by a build with a cipher this one does
      // not have would otherwise be "read" as base64 nonsense and then
      // *overwritten* by the next save, destroying values that were fine.
      _logger?.warning(
        'Environment vault was written with cipher "$storedCipher"; this build '
        'has "${_cipher.id}".',
      );
      return _data = EnvVaultData.unavailable(
        'These environment variables were saved by a different version of '
        'Karmashala and cannot be read by this one. Nothing has been changed.',
        canStoreSecrets: canStoreSecrets,
      );
    }

    final rows = json['variables'];
    final variables = <EnvVariable>[];
    var skipped = 0;
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final stored = row['value'];
        final value = stored is String ? await _cipher.unwrap(stored) : null;
        final variable = value == null
            ? null
            : EnvVariable.fromJson(row, value);
        if (variable == null) {
          skipped++;
          continue;
        }
        variables.add(variable);
      }
    }
    if (skipped > 0) {
      // The count, never the rows: a malformed row's own contents are exactly
      // what must not reach a log line.
      _logger?.warning('Environment vault: $skipped record(s) ignored.');
    }
    _logger?.info(
      'Environment vault loaded ${variables.length} variable(s) '
      '(protection: ${_protection.name}).',
    );
    return _data = EnvVaultData(
      enabled: json['enabled'] != false,
      variables: variables,
      protection: _protection,
      canStoreSecrets: canStoreSecrets,
    );
  }

  EnvProtection get _protection => _cipher is PlaintextEnvValueCipher
      ? EnvProtection.filePermissions
      : EnvProtection.localKey;

  /// Writes [next] and returns what is now in force.
  ///
  /// **Fail-closed on secrets.** If the directory ACL could not be applied,
  /// saving a secret variable is refused outright rather than written under
  /// permissions that were not applied — the same call
  /// `LauncherControlServer` makes about its privileged token, for the same
  /// reason. Plain variables are unaffected: they are not claiming a protection
  /// they do not have.
  Future<EnvVaultData> save(EnvVaultData next) async {
    if (_directory == null) {
      throw const EnvVaultRefusal(
        'There is nowhere to save environment variables in this session.',
      );
    }
    if (!_data.canStoreSecrets && next.variables.any((v) => v.secret)) {
      throw const EnvVaultRefusal(
        'Karmashala could not restrict the environment variables folder to '
        'your account, so it will not store a secret there.',
      );
    }

    final rows = <Map<String, dynamic>>[];
    for (final variable in next.variables) {
      rows.add({
        ...variable.toJsonWithoutValue(),
        'value': await _cipher.wrap(variable.value),
      });
    }
    final payload = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'enabled': next.enabled,
      'enc': _cipher.id,
      'variables': rows,
    });

    // Written to a sibling and renamed over the target, so a crash mid-write
    // leaves the previous vault intact rather than a truncated one. The
    // directory's ACL is inheritable (`(OI)(CI)` on Windows, `0700` on POSIX),
    // so the temp file is born restricted; it is restricted again explicitly
    // because being born right is a property of the directory, and this file
    // must not depend on that staying true.
    final target = _file;
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsString(payload, flush: true);
      await _permissions.restrictFile(temp, logger: _logger);
      await temp.rename(target.path);
      await _permissions.restrictFile(target, logger: _logger);
    } on Object catch (error) {
      _logger?.warning('Environment vault could not be written: $error');
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } on Object {
          // Nothing useful to do; the next save overwrites it.
        }
      }
      throw EnvVaultRefusal('Could not save: $error');
    }

    _logger?.info(
      'Environment vault saved ${next.variables.length} variable(s).',
    );
    return _data = next.copyWith(
      protection: _protection,
      canStoreSecrets: _data.canStoreSecrets,
      clearProblem: true,
    );
  }
}
