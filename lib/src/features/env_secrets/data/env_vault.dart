// The collaborators are named for callers (`directory:`, `cipher:`) but stored
// privately, which the initializing-formals lint cannot express: a named
// parameter may not start with an underscore, so `this._directory` — the fix it
// suggests — does not compile. Same reason, same ignore, as
// `secure_companion_store.dart`.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:karmashala_core/logging.dart';
import '../../mcp/handshake_file_permissions.dart';
import '../domain/env_variable.dart';
import 'env_value_cipher.dart';
import 'local_key_cipher.dart';
import '../../../core/paths/app_support_directory.dart';

/// Raised when the vault refuses to store something rather than storing it
/// less well than promised.
class EnvVaultRefusal implements Exception {
  const EnvVaultRefusal(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The environment variables on disk: one JSON file in a directory restricted
/// to this account, deliberately not the database — see docs/SETTLED.md.
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
  /// secrets. The **default**, because this feature must never stop a terminal.
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

  /// Set when the vault on disk could not be fully understood. While it is set
  /// [save] refuses, so the next edit cannot overwrite merely unreadable values.
  bool _readOnly = false;

  /// Whether the vault is refusing writes because what is on disk could not be
  /// read. The settings page offers "Try again" rather than an editor.
  bool get isReadOnly => _readOnly;

  /// The last loaded or saved state. Never null; an unreadable vault is
  /// [EnvVaultData.unavailable], not an exception thrown at a caller who only
  /// wanted to open a shell.
  EnvVaultData get data => _data;

  /// The file name inside the restricted directory.
  static const String fileName = 'env.json';

  /// The directory the vault lives in, under application support.
  static const String directoryName = 'secrets';

  /// The real vault, hardened, values encrypted under a key in the local
  /// directory. A machine that cannot hold a key falls back and **says so**.
  static Future<EnvVault> open({AppLogger? logger}) async {
    final support = await appSupportDirectory();
    EnvValueCipher cipher;
    try {
      cipher = await LocalKeyEnvValueCipher.open(logger: logger);
    } on Object catch (error) {
      logger?.warning(
        'Environment vault will use file permissions only: $error',
      );
      cipher = const PlaintextEnvValueCipher();
    }
    return EnvVault(
      directory: Directory(p.join(support.path, directoryName)),
      cipher: cipher,
      logger: logger,
    );
  }

  File get _file => File(p.join(_directory!.path, fileName));

  /// Creates and hardens the directory, then reads what is in it. Never throws:
  /// every failure becomes an [EnvVaultData] that says what is wrong.
  Future<EnvVaultData> load() async {
    _readOnly = false;
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
      _readOnly = true;
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
      _readOnly = true;
      return _data = EnvVaultData.unavailable(
        'These environment variables were saved by a different version of '
        'Karmashala and cannot be read by this one. Nothing has been changed.',
        canStoreSecrets: canStoreSecrets,
      );
    }

    final rows = json['variables'];
    final variables = <EnvVariable>[];
    var skipped = 0;
    // Counted apart from [skipped] because they mean opposite things: a malformed
    // record is one bad row; one that will not decrypt means the *key* is gone.
    var undecryptable = 0;
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final stored = row['value'];
        if (stored is! String) {
          skipped++;
          continue;
        }
        final value = await _cipher.unwrap(stored);
        if (value == null) {
          undecryptable++;
          continue;
        }
        final variable = EnvVariable.fromJson(row, value);
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
    if (undecryptable > 0) {
      _logger?.warning(
        'Environment vault: $undecryptable record(s) could not be decrypted; '
        'refusing to overwrite them.',
      );
      _readOnly = true;
      return _data = EnvVaultData.unavailable(
        '$undecryptable saved environment ${undecryptable == 1 ? 'variable' : 'variables'} '
        'could not be decrypted — the key that protects them is missing or has '
        'changed. They are still on disk and Karmashala will not overwrite '
        'them, but it cannot recover them either: remove and re-enter them.',
        canStoreSecrets: canStoreSecrets,
      );
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

  /// Writes [next] and returns what is now in force. **Fail-closed on secrets**:
  /// if the ACL could not be applied, saving a secret is refused outright.
  Future<EnvVaultData> save(EnvVaultData next) async {
    if (_directory == null) {
      throw const EnvVaultRefusal(
        'There is nowhere to save environment variables in this session.',
      );
    }
    if (_readOnly) {
      throw const EnvVaultRefusal(
        'The saved environment variables could not be read, so Karmashala will '
        'not write over them.',
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
    // leaves the previous vault intact. Restricted explicitly, not by inheritance.
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
