import 'package:karmashala_core/logging.dart';
import 'package:test/test.dart';

/// The shapes a real secret takes in this app's logs. Each is fake, but each is
/// spelled the way the thing it stands for actually is.
const kAnthropicToken = 'sk-ant-api03-Zx9Qw8Lm2Nv4Bt7Rk1Cy6Hd0Sf3Jg5Pu-AA';
const kGithubToken = 'ghp_9aB3cD5eF7gH9iJ1kL3mN5oP7qR9sT1uV3wX';
const kJwt =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const kHostKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH4tFbGqDLrRcYqPZ0mQeRs7WvKjBnXyTgAsDfGhJkLm';
const kFingerprint = 'SHA256:47DEQpj8HBSaTImW5JCeuQeRkm5NMpJWZG3hSuFU';

void main() {
  final redactor = LogRedactor();

  group('LogRedactor', () {
    test('an Anthropic key never survives', () {
      final out = redactor.apply('refreshing with $kAnthropicToken now');
      expect(out, isNot(contains(kAnthropicToken)));
      expect(out, isNot(contains('sk-ant-api03')));
      expect(out, contains('[redacted:token]'));
      expect(out, startsWith('refreshing with '));
    });

    test('a GitHub token and a JWT never survive', () {
      expect(redactor.apply(kGithubToken), '[redacted:token]');
      expect(
        redactor.apply('Authorization: Bearer $kJwt'),
        isNot(contains(kJwt)),
      );
      expect(redactor.apply(kJwt), '[redacted:token]');
    });

    test('an ssh host key keeps its algorithm and loses its bytes', () {
      final out = redactor.apply('host key changed: $kHostKey');
      expect(out, isNot(contains('AAAAC3NzaC1lZDI1NTE5')));
      // The algorithm is the diagnosable half, so it stays.
      expect(out, 'host key changed: ssh-ed25519 [redacted:key]');
    });

    test('a key fingerprint never survives', () {
      final out = redactor.apply('fingerprint $kFingerprint for build-box');
      expect(out, isNot(contains('47DEQpj8')));
      expect(out, contains('SHA256:[redacted:key]'));
      expect(out, endsWith('for build-box'));
    });

    test('a private key block never survives', () {
      const pem =
          '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB\n'
          '-----END OPENSSH PRIVATE KEY-----';
      final out = redactor.apply('loaded $pem from disk');
      expect(out, isNot(contains('b3BlbnNzaC1rZXk')));
      expect(out, 'loaded [redacted:private-key] from disk');
    });

    test('anything spelled like an assigned secret is dropped', () {
      expect(
        redactor.apply('pairing failed token=hunter2seventeen code'),
        'pairing failed token=[redacted] code',
      );
      expect(
        redactor.apply('device_key: "aBcDeFgHiJkLmNoP"'),
        'device_key: [redacted]',
      );
      expect(
        redactor.apply('client_secret=abcdefghijkl'),
        'client_secret=[redacted]',
      );
    });

    test('the user is taken out of home paths, on every host spelling', () {
      expect(
        redactor.apply(r'opening C:\Users\dlohani\projects\app'),
        r'opening C:\Users\<user>\projects\app',
      );
      expect(
        redactor.apply('opening /home/dlohani/src/app'),
        'opening /home/<user>/src/app',
      );
      expect(
        redactor.apply('opening /Users/dlohani/src/app'),
        'opening /Users/<user>/src/app',
      );
      expect(
        redactor.apply(r'opening \\wsl.localhost\Ubuntu\home\dlohani\src'),
        r'opening \\wsl.localhost\Ubuntu\home\<user>\src',
      );
    });

    test('ordinary messages are left alone', () {
      const lines = [
        'Starting Karmashala.',
        'Discovered 3 execution environment(s).',
        'session s-42 moved from working to waiting',
        'host key verification: ok',
        'claude-auth: refreshing for account 2',
        'connect failed: Connection refused (errno = 111)',
      ];
      for (final line in lines) {
        expect(redactor.apply(line), line, reason: line);
      }
    });

    test('redacting twice changes nothing more', () {
      const line =
          r'token=hunter2seventeen at C:\Users\dlohani\a and key '
          '$kHostKey';
      final once = redactor.apply(line);
      expect(redactor.apply(once), once);
    });

    test('a new rule is two lines', () {
      final custom = LogRedactor(
        rules: [
          RedactionRule(
            name: 'test rule',
            pattern: RegExp(r'\bKARMA-[0-9]{4}\b'),
            replacement: '[redacted:code]',
          ),
        ],
      );
      expect(custom.apply('pair with KARMA-4821'), 'pair with [redacted:code]');
    });
  });
}
