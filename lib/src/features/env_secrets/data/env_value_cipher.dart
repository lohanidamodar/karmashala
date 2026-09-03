import 'dart:convert';

/// Wraps and unwraps one stored value.
///
/// The seam exists so the vault does not care *how* a value is protected, only
/// that it round-trips. Phase 1 ships [PlaintextEnvValueCipher]; the encrypting
/// implementation slots in behind the same two methods.
///
/// [id] is written into the vault file and is what the settings page reports.
/// A vault whose `enc` names a cipher this build does not have is not guessed
/// at — see `EnvVault.load`.
abstract class EnvValueCipher {
  const EnvValueCipher();

  /// The identifier stored as `enc` in the vault file.
  String get id;

  Future<String> wrap(String plaintext);

  /// Returns null when [stored] cannot be recovered — a corrupt record, or a
  /// key that no longer matches. One bad row must not take the vault down.
  Future<String?> unwrap(String stored);
}

/// No encryption: the value is stored as written, and the file permissions are
/// the whole boundary.
///
/// Base64 rather than raw so the JSON is byte-identical in shape to an
/// encrypted vault — a value containing a quote, a newline or a non-BMP
/// character takes the same path either way, so the encrypted implementation
/// cannot be the one that discovers an escaping bug.
class PlaintextEnvValueCipher extends EnvValueCipher {
  const PlaintextEnvValueCipher();

  @override
  String get id => 'none';

  @override
  Future<String> wrap(String plaintext) async =>
      base64.encode(utf8.encode(plaintext));

  @override
  Future<String?> unwrap(String stored) async {
    try {
      return utf8.decode(base64.decode(stored));
    } on Object {
      return null;
    }
  }
}
