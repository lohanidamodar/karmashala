import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  /// Which path shapes name a Windows file, and which are left where they are.
  /// The cost that picks them is in [gitProbeTargetFor]; nothing here times
  /// anything.
  group('gitProbeTargetFor', () {
    /// The host lookup, counting the times it was needed.
    ({GitProbeTarget target, int lookups}) probe(
      String environmentId,
      String path, {
      String? host = 'windows',
    }) {
      var lookups = 0;
      final environment = switch (environmentId) {
        'windows' => windowsEnv(),
        'ssh:h1' => sshEnvFixture(),
        _ => wslEnv(),
      };
      final target = gitProbeTargetFor(
        EnvironmentPath(environmentId: environmentId, path: path),
        environment,
        windowsHost: () {
          lookups++;
          return switch (host) {
            'windows' => windowsEnv(),
            'posix' => posixEnv(),
            _ => null,
          };
        },
      );
      return (target: target, lookups: lookups);
    }

    test('a /mnt drive path in a WSL row is a Windows file', () {
      final answer = probe('wsl:Ubuntu', '/mnt/c/src/app').target;

      expect(answer.environment.id, 'windows');
      expect(answer.path.environmentId, 'windows');
      expect(answer.path.path, r'C:\src\app');
    });

    test('the drive root too', () {
      expect(probe('wsl:Ubuntu', '/mnt/c').target.path.path, r'C:\');
    });

    test('an ext4 path stays where it already costs 9 ms', () {
      final answer = probe('wsl:Ubuntu', '/home/me/app').target;

      expect(answer.environment.id, 'wsl:Ubuntu');
      expect(answer.path.path, '/home/me/app');
    });

    test('a distribution that automounts elsewhere is not guessed at', () {
      // `[automount] root = /windir/` really does put `C:` at `/windir/c`, and
      // reading `wsl.conf` costs the spawn this is avoiding.
      final answer = probe('wsl:Ubuntu', '/windir/c/src/app').target;

      expect(answer.environment.id, 'wsl:Ubuntu');
      expect(answer.path.path, '/windir/c/src/app');
    });

    test('/mnt/wsl is not a drive', () {
      final answer = probe('wsl:Ubuntu', '/mnt/wsl/docker-desktop/x').target;

      expect(answer.environment.id, 'wsl:Ubuntu');
    });

    test('the reverse direction is not taken', () {
      // §18 measures `\\wsl.localhost` as working but slow, and
      // `Directory.watch` on it never fires. Moving a probe onto the share
      // would be moving it the wrong way.
      final answer = probe(
        'wsl:Ubuntu',
        r'\\wsl.localhost\Ubuntu\home\me\app',
      ).target;

      expect(answer.environment.id, 'wsl:Ubuntu');
      expect(answer.path.path, r'\\wsl.localhost\Ubuntu\home\me\app');
    });

    test('no host row recorded falls back rather than throwing', () {
      final answer = probe('wsl:Ubuntu', '/mnt/c/app', host: null).target;

      expect(answer.environment.id, 'wsl:Ubuntu');
      expect(answer.path.path, '/mnt/c/app');
    });

    test('a host row that is not Windows falls back', () {
      // A database carried to a Mac keeps its `wsl:` rows; `C:\app` must not
      // reach that machine's shell. Read off the row's kind, not `Platform`.
      final answer = probe('wsl:Ubuntu', '/mnt/c/app', host: 'posix').target;

      expect(answer.environment.id, 'wsl:Ubuntu');
      expect(answer.path.path, '/mnt/c/app');
    });

    test('a checkout that is not in WSL never spends the lookup', () {
      expect(probe('windows', r'C:\app').lookups, 0);
      expect(probe('ssh:h1', '/home/me/app').lookups, 0);
    });

    test('Windows and SSH checkouts are handed back unchanged', () {
      expect(probe('windows', r'C:\app').target.environment.id, 'windows');
      expect(probe('windows', r'C:\app').target.path.path, r'C:\app');
      expect(probe('ssh:h1', '/home/me/app').target.environment.id, 'ssh:h1');
    });
  });
}
