// `key:` is named for callers but stored privately, and a named parameter may
// not start with an underscore — so `this._key`, the fix this lint suggests,
// does not compile. Same reason and same ignore as `env_vault.dart`.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_logger.dart';
import '../../mcp/handshake_file_permissions.dart';
import 'env_value_cipher.dart';

/// Raised when the key exists but cannot be used, or cannot be created.
class EnvKeyUnavailable implements Exception {
  const EnvKeyUnavailable(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Bytes in the vault key. 32, because XChaCha20 takes a 256-bit key.
const int kEnvKeyBytes = 32;

/// The nonce and MAC lengths `Xchacha20.poly1305Aead()` concatenates around a
/// ciphertext — the same framing `push_crypto.dart` uses.
const int _nonceBytes = 24;
const int _macBytes = 16;

/// Additional authenticated data, so a sealed value from this vault cannot be
/// replayed into another sealed field elsewhere in the app.
const String _aad = 'karmashala:env-vault:v1';

/// Encrypts vault values with a key kept **outside the vault**, in the
/// platform's local (non-roaming) per-user directory.
///
/// ## Why this, and not a per-platform keystore
///
/// The obvious answer was DPAPI on Windows, Keychain on macOS, libsecret on
/// Linux. Three native integrations, three failure modes, and on Linux a
/// dependency that is simply absent on a headless or minimal box. This repo
/// already has the scar: `flutter_secure_storage` — the one cross-platform
/// secure store it tried — is **stubbed out to throw on Windows**
/// (`packages/flutter_secure_storage_windows_stub`), because every published
/// 4.x Windows implementation needs ATL and the VS 2026 toolchain has none.
/// The primary platform is the one that lost.
///
/// So: recall what DPAPI was actually buying. Not protection from a process
/// running as this user — there is none, and there cannot be, because the app
/// must read these values with no prompt in order to start a terminal. What it
/// bought was that **a copy of the vault taken off the machine is inert**,
/// which matters here specifically because `getApplicationSupportDirectory()`
/// on Windows is `%APPDATA%` — *Roaming* — and roaming profiles, folder
/// redirection and backup tools sweep that up.
///
/// A random key in a non-roaming directory delivers exactly that property, with
/// one implementation and no FFI:
///
///  * Windows — `%LOCALAPPDATA%\…`, which by definition does not roam.
///  * macOS — `~/Library/Caches/…`, which Time Machine excludes by default.
///  * Linux — `$XDG_CACHE_HOME` (`~/.cache`), conventionally excluded from
///    dotfile sync and most backup profiles.
///
/// `getApplicationCacheDirectory()` is all three, so there is no platform
/// branch here at all. The key file gets the same ACL / `0600` treatment as the
/// vault, so it is not readable by another account either.
///
/// ## What it does not protect against, plainly
///
///  * **Anything running as you.** The key is readable without a prompt,
///    because the app reads it without a prompt. This is unchanged from
///    phase 1 and is inherent to the feature.
///  * **A local administrator**, who can take ownership of both files.
///  * **A whole-home backup**, which takes the vault and the key together. That
///    is outside what any of this can defend — such a backup has the user's SSH
///    keys in it too.
///
/// What it *does* defend is the realistic accident: the vault file, or the
/// application-support subtree holding it, ending up somewhere else — a bug
/// report, a synced folder, a roaming profile, another machine.
///
/// ## Losing the key
///
/// A cleared cache directory means the values cannot be decrypted. That is
/// handled loudly rather than silently: [unwrap] returns null, `EnvVault`
/// reports a problem and **does not overwrite** the vault, so the user is told
/// to re-enter the values rather than discovering later that they were
/// replaced with nonsense. Phase 1's ACL stands on its own underneath this.
class LocalKeyEnvValueCipher extends EnvValueCipher {
  LocalKeyEnvValueCipher({required SecretKeyData key}) : _key = key;

  final SecretKeyData _key;

  @override
  String get id => 'local-key';

  /// The key file's name, inside the local directory.
  static const String keyFileName = 'env.key';

  /// The directory the key lives in, under the local (cache) root.
  static const String directoryName = 'secrets';

  /// Loads the key, creating one on first use.
  ///
  /// Throws [EnvKeyUnavailable] when the key cannot be created or read, which
  /// `EnvVault` turns into "fall back to file permissions only" rather than
  /// into a failed launch.
  static Future<LocalKeyEnvValueCipher> open({
    Directory? directory,
    HandshakePermissions permissions = const SystemHandshakePermissions(),
    AppLogger? logger,
    Random? random,
  }) async {
    final dir =
        directory ??
        Directory(
          p.join((await getApplicationCacheDirectory()).path, directoryName),
        );
    try {
      await dir.create(recursive: true);
      await permissions.restrictDirectory(dir, logger: logger);
    } on Object catch (error) {
      throw EnvKeyUnavailable('key folder could not be created: $error');
    }

    final file = File(p.join(dir.path, keyFileName));
    if (file.existsSync()) {
      final bytes = await _read(file);
      return LocalKeyEnvValueCipher(key: SecretKeyData(bytes));
    }

    // Created and restricted before the bytes go in it — the same order
    // `LauncherControlServer` writes its handshake, and for the same reason:
    // a key must never exist, even for an instant, under permissions that were
    // not applied.
    final generator = random ?? Random.secure();
    final bytes = Uint8List.fromList([
      for (var i = 0; i < kEnvKeyBytes; i++) generator.nextInt(256),
    ]);
    try {
      await file.create();
      final restricted = await permissions.restrictFile(file, logger: logger);
      if (!restricted) {
        // Do not leave a half-made key behind for the next run to adopt.
        if (file.existsSync()) file.deleteSync();
        throw const EnvKeyUnavailable(
          'the key file could not be restricted to this account',
        );
      }
      await file.writeAsString(base64.encode(bytes), flush: true);
    } on EnvKeyUnavailable {
      rethrow;
    } on Object catch (error) {
      throw EnvKeyUnavailable('key could not be written: $error');
    }
    logger?.info('Created a new environment vault key.');
    return LocalKeyEnvValueCipher(key: SecretKeyData(bytes));
  }

  static Future<Uint8List> _read(File file) async {
    final Uint8List bytes;
    try {
      bytes = base64.decode((await file.readAsString()).trim());
    } on Object catch (error) {
      throw EnvKeyUnavailable('key could not be read: $error');
    }
    if (bytes.length != kEnvKeyBytes) {
      throw const EnvKeyUnavailable('key is the wrong length');
    }
    return bytes;
  }

  @override
  Future<String> wrap(String plaintext) async {
    final cipher = Xchacha20.poly1305Aead();
    final box = await cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: _key,
      aad: _aad.codeUnits,
    );
    return base64.encode(box.concatenation());
  }

  @override
  Future<String?> unwrap(String stored) async {
    final Uint8List sealed;
    try {
      sealed = base64.decode(stored);
    } on FormatException {
      return null;
    }
    if (sealed.length < _nonceBytes + _macBytes) return null;
    try {
      final opened = await Xchacha20.poly1305Aead().decrypt(
        SecretBox.fromConcatenation(
          sealed,
          nonceLength: _nonceBytes,
          macLength: _macBytes,
        ),
        secretKey: _key,
        aad: _aad.codeUnits,
      );
      return utf8.decode(opened);
    } on Object {
      // A wrong key, a truncated record, a tampered one. All the same answer:
      // this value is not recoverable, and the caller must not overwrite it.
      return null;
    }
  }
}
