import 'dart:convert';

/// Wraps and unwraps one stored value. [id] is written into the vault file: a
/// vault naming a cipher this build lacks is refused, never guessed at.
abstract class EnvValueCipher {
  const EnvValueCipher();

  /// The identifier stored as `enc` in the vault file.
  String get id;

  Future<String> wrap(String plaintext);

  /// Returns null when [stored] cannot be recovered — a corrupt record, or a
  /// key that no longer matches. One bad row must not take the vault down.
  Future<String?> unwrap(String stored);
}

/// No encryption: the file permissions are the whole boundary. Base64 so the
/// JSON is byte-identical in shape to an encrypted vault's.
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
