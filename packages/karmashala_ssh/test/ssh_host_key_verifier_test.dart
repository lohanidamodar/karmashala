import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_ssh/connection.dart';
import 'package:test/test.dart';

import 'support.dart';

/// dartssh2 hands the callback the UTF-8 of `SHA256:<base64>`.
Uint8List fp(String value) => Uint8List.fromList(utf8.encode(value));

const _good = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _evil = 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

void main() {
  late MemoryKnownHosts known;

  setUp(() => known = MemoryKnownHosts());

  SshHostKeyVerifier verifier({HostKeyTrustDecision? onUnknown}) =>
      SshHostKeyVerifier(
        knownHosts: known,
        host: 'build-box',
        port: 22,
        clock: FixedClock(testTime),
        onUnknownHostKey: onUnknown,
      );

  test('an unknown host is refused when nothing can ask the user', () async {
    final v = verifier();
    expect(await v.verify('ssh-ed25519', fp(_good)), isFalse);
    expect(v.lastPresentation!.verdict, HostKeyVerdict.unknown);
    expect(known.find('build-box', 22), isNull);
  });

  test('an unknown host is refused when the user declines', () async {
    var asked = 0;
    final v = verifier(
      onUnknown: (_) {
        asked++;
        return false;
      },
    );
    expect(await v.verify('ssh-ed25519', fp(_good)), isFalse);
    expect(asked, 1);
    expect(known.find('build-box', 22), isNull);
  });

  test('accepting on first use pins the key for next time', () async {
    HostKeyPresentation? shown;
    final v = verifier(
      onUnknown: (p) {
        shown = p;
        return true;
      },
    );
    expect(await v.verify('ssh-ed25519', fp(_good)), isTrue);
    expect(shown!.fingerprint, _good);
    expect(shown!.verdict, HostKeyVerdict.unknown);

    final stored = known.find('build-box', 22)!;
    expect(stored.fingerprint, _good);
    expect(stored.keyType, 'ssh-ed25519');
    expect(stored.trustedAt, testTime);

    // Second connection: matches, so the user is not asked again.
    var askedAgain = false;
    final v2 = verifier(
      onUnknown: (_) {
        askedAgain = true;
        return true;
      },
    );
    expect(await v2.verify('ssh-ed25519', fp(_good)), isTrue);
    expect(askedAgain, isFalse);
    expect(v2.lastPresentation!.verdict, HostKeyVerdict.trusted);
  });

  test('a changed key is refused and the user is never asked', () async {
    known.trust(
      KnownHostKey(
        host: 'build-box',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _good,
        trustedAt: testTime,
      ),
    );

    var asked = false;
    final v = verifier(
      onUnknown: (_) {
        asked = true;
        return true; // Would accept anything — must never be consulted.
      },
    );
    expect(await v.verify('ssh-ed25519', fp(_evil)), isFalse);
    expect(asked, isFalse, reason: 'a changed key is not a user decision');
    expect(v.lastPresentation!.verdict, HostKeyVerdict.changed);
    // The pinned key is untouched, so a later legitimate connection still works.
    expect(known.find('build-box', 22)!.fingerprint, _good);
  });

  test(
    'a different key algorithm for a pinned host also counts as changed',
    () async {
      known.trust(
        KnownHostKey(
          host: 'build-box',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: _good,
          trustedAt: testTime,
        ),
      );
      final v = verifier(onUnknown: (_) => true);
      expect(await v.verify('ssh-rsa', fp(_good)), isFalse);
      expect(v.lastPresentation!.verdict, HostKeyVerdict.changed);
    },
  );

  test('the same host on another port is a separate identity', () async {
    known.trust(
      KnownHostKey(
        host: 'build-box',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _good,
        trustedAt: testTime,
      ),
    );
    final other = SshHostKeyVerifier(
      knownHosts: known,
      host: 'build-box',
      port: 2222,
      clock: FixedClock(testTime),
    );
    expect(
      other.classify('ssh-ed25519', _good).verdict,
      HostKeyVerdict.unknown,
    );
  });

  test(
    'forgetting a host makes the next connection a first connection',
    () async {
      known.trust(
        KnownHostKey(
          host: 'build-box',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: _good,
          trustedAt: testTime,
        ),
      );
      known.forget('build-box', 22);
      expect(
        verifier().classify('ssh-rsa', _evil).verdict,
        HostKeyVerdict.unknown,
      );
    },
  );

  test('a key the server will not record is refused, not trusted', () async {
    // Another client trusted a different key for this address while the
    // person was deciding: the server keeps the first, and this connection
    // is refused like a changed key.
    final v = verifier(
      onUnknown: (_) {
        known.trust(
          KnownHostKey(
            host: 'build-box',
            port: 22,
            keyType: 'ssh-ed25519',
            fingerprint: _evil,
            trustedAt: testTime,
          ),
        );
        return true;
      },
    );
    expect(await v.verify('ssh-ed25519', fp(_good)), isFalse);
    expect(known.find('build-box', 22)!.fingerprint, _evil);
  });

  test('the changed-key message names both fingerprints', () {
    final message = HostKeyPresentation(
      host: 'build-box',
      port: 22,
      keyType: 'ssh-rsa',
      fingerprint: _evil,
      verdict: HostKeyVerdict.changed,
      known: KnownHostKey(
        host: 'build-box',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: _good,
        trustedAt: testTime,
      ),
    ).describe();
    expect(message, contains('HAS CHANGED'));
    expect(message, contains(_good));
    expect(message, contains(_evil));
  });
}
