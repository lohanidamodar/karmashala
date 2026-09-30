import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:store_console/store_console.dart';

import 'apple_api_key.dart';

/// Apple refuses a team token that lives longer than 20 minutes.
const appleTokenLifetime = Duration(minutes: 15);

const _resignBefore = Duration(minutes: 1);

/// The payload App Store Connect asks of a team key.
Map<String, Object?> appleTokenClaims({
  required String issuerId,
  required DateTime issuedAt,
}) {
  final iat = issuedAt.millisecondsSinceEpoch ~/ 1000;
  return {
    'iss': issuerId,
    'iat': iat,
    'exp': iat + appleTokenLifetime.inSeconds,
    'aud': 'appstoreconnect-v1',
  };
}

/// Signs the bearer token and keeps it until a minute before it expires.
class AppleTokenSigner {
  AppleTokenSigner(this._key, this._now);

  final AppleApiKey _key;
  final DateTime Function() _now;

  ECPrivateKey? _privateKey;
  String? _token;
  DateTime? _expires;

  /// Throws [StoreException] with [StoreFailure.auth] for a key that cannot
  /// be read or signed with.
  String token() {
    final now = _now();
    final token = _token;
    final expires = _expires;
    if (token != null &&
        expires != null &&
        now.isBefore(expires.subtract(_resignBefore))) {
      return token;
    }
    final problem = _key.problem;
    if (problem != null) throw StoreException(StoreFailure.auth, problem);
    try {
      final privateKey = _privateKey ??= ECPrivateKey(_key.privateKeyPem);
      // The library stamps iat from the wall clock; the claims carry ours.
      final signed = JWT(
        appleTokenClaims(issuerId: _key.issuerId.trim(), issuedAt: now),
        header: {'kid': _key.keyId.trim()},
      ).sign(privateKey, algorithm: JWTAlgorithm.ES256, noIssueAt: true);
      _token = signed;
      _expires = now.add(appleTokenLifetime);
      return signed;
    } catch (_) {
      // The error's own text may quote key bytes, so it is not passed on.
      throw const StoreException(
        StoreFailure.auth,
        'The .p8 private key could not be read. Import the file again, '
        'exactly as App Store Connect gave it.',
      );
    }
  }
}
