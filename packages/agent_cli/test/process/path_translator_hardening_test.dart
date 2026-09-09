import 'package:agent_cli/src/process/path_translator.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  const t = PathTranslator();
  final windows = windowsEnv();
  final ubuntu = wslEnv();

  EnvironmentPath p(String env, String path) =>
      EnvironmentPath(environmentId: env, path: path);

  group('windowsDriveToWslMount edge cases', () {
    test('forward slashes', () {
      expect(t.windowsDriveToWslMount('C:/Users/me'), '/mnt/c/Users/me');
    });
    test('trailing separators are trimmed', () {
      expect(t.windowsDriveToWslMount(r'C:\Users\me\'), '/mnt/c/Users/me');
    });
    test('bare drive maps to the mount root', () {
      expect(t.windowsDriveToWslMount('D:'), '/mnt/d');
      expect(t.windowsDriveToWslMount(r'D:\'), '/mnt/d');
    });
  });

  group('wslMountToWindowsDrive edge cases', () {
    test('drive root', () {
      expect(t.wslMountToWindowsDrive('/mnt/c'), r'C:\');
      expect(t.wslMountToWindowsDrive('/mnt/c/'), r'C:\');
    });
    test('trailing slash trimmed', () {
      expect(t.wslMountToWindowsDrive('/mnt/c/a/b/'), r'C:\a\b');
    });
  });

  group('translate edge cases', () {
    test('round-trips a /mnt path WSL → Windows → WSL', () {
      const start = '/mnt/c/src/app';
      final win = t.translate(
        p('wsl:Ubuntu', start),
        from: ubuntu,
        to: windows,
      );
      final back = t.translate(win, from: windows, to: ubuntu);
      expect(back.path, start);
    });

    test('WSL root maps to a bare UNC root', () {
      final r = t.translate(p('wsl:Ubuntu', '/'), from: ubuntu, to: windows);
      expect(r.path, r'\\wsl.localhost\Ubuntu');
    });

    test(
      'UNC (\$ form, trailing slash) back to WSL for the matching distro',
      () {
        final r = t.translate(
          p('windows', r'\\wsl$\Ubuntu\home\me\'),
          from: windows,
          to: ubuntu,
        );
        expect(r.path, '/home/me');
      },
    );
  });
}
