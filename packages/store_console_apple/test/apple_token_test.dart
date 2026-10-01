import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:store_console/store_console.dart';
import 'package:store_console_apple/src/apple_token.dart';
import 'package:store_console_apple/store_console_apple.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('the claims are the ones App Store Connect asks for', () {
    final claims = appleTokenClaims(issuerId: 'issuer', issuedAt: fixedNow);
    final iat = fixedNow.millisecondsSinceEpoch ~/ 1000;
    expect(claims, {
      'iss': 'issuer',
      'iat': iat,
      'exp': iat + 15 * 60,
      'aud': 'appstoreconnect-v1',
    });
  });

  test('the token is ES256, names the key, and carries the injected time', () {
    final key = testKey();
    final token = AppleTokenSigner(key, () => fixedNow).token();
    expect(token.split('.'), hasLength(3));

    final decoded = JWT.decode(token);
    expect(decoded.header, {'kid': key.keyId, 'alg': 'ES256', 'typ': 'JWT'});
    final payload = (decoded.payload as Map).cast<String, Object?>();
    final iat = fixedNow.millisecondsSinceEpoch ~/ 1000;
    expect(payload['iss'], key.issuerId);
    expect(payload['aud'], 'appstoreconnect-v1');
    expect(payload['iat'], iat);
    expect(payload['exp'], iat + 15 * 60);
  });

  test('the token is kept until a minute before it expires', () {
    var now = fixedNow;
    final signer = AppleTokenSigner(testKey(), () => now);
    final first = signer.token();

    now = fixedNow.add(const Duration(minutes: 13, seconds: 59));
    expect(signer.token(), same(first));

    now = fixedNow.add(const Duration(minutes: 14));
    final second = signer.token();
    final payload = (JWT.decode(second).payload as Map).cast<String, Object?>();
    expect(payload['iat'], now.millisecondsSinceEpoch ~/ 1000);
  });

  test('a key that cannot be parsed is an auth failure without its text', () {
    const pem =
        '-----BEGIN PRIVATE KEY-----\nbm90IGEga2V5\n-----END PRIVATE KEY-----';
    final signer = AppleTokenSigner(
      const AppleApiKey(keyId: 'K', issuerId: 'I', privateKeyPem: pem),
      () => fixedNow,
    );
    expect(
      signer.token,
      throwsA(
        isA<StoreException>()
            .having((e) => e.kind, 'kind', StoreFailure.auth)
            .having((e) => e.message, 'message', isNot(contains('bm90'))),
      ),
    );
  });

  test('a key with no key ID is refused before signing', () {
    final signer = AppleTokenSigner(
      AppleApiKey(keyId: ' ', issuerId: 'I', privateKeyPem: throwawayPem()),
      () => fixedNow,
    );
    expect(signer.token, storeFailure(StoreFailure.auth));
  });
}
