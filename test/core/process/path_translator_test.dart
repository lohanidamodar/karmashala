import 'package:karmashala/src/core/process/path_translator.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  const t = PathTranslator();
  final windows = windowsEnv();
  final ubuntu = wslEnv();

  group('drive <-> /mnt', () {
    test('Windows drive path to WSL mount', () {
      expect(
        t.windowsDriveToWslMount(r'C:\Users\me\repo'),
        '/mnt/c/Users/me/repo',
      );
      expect(t.windowsDriveToWslMount(r'D:\'), '/mnt/d');
    });

    test('WSL mount to Windows drive path', () {
      expect(
        t.wslMountToWindowsDrive('/mnt/c/Users/me/repo'),
        r'C:\Users\me\repo',
      );
      expect(t.wslMountToWindowsDrive('/mnt/d'), r'D:\');
    });

    test('rejects a non-drive Windows path', () {
      expect(
        () => t.windowsDriveToWslMount(r'\\server\share'),
        throwsA(isA<PathTranslationException>()),
      );
    });
  });

  group('translate between environments', () {
    test('same environment returns the path unchanged', () {
      const p = EnvironmentPath(environmentId: 'windows', path: r'C:\x');
      expect(t.translate(p, from: windows, to: windows), p);
    });

    test('Windows -> WSL drive path', () {
      const p = EnvironmentPath(environmentId: 'windows', path: r'C:\src\app');
      final r = t.translate(p, from: windows, to: ubuntu);
      expect(r.environmentId, 'wsl:Ubuntu');
      expect(r.path, '/mnt/c/src/app');
    });

    test('WSL -> Windows /mnt path', () {
      const p = EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/mnt/c/src/app',
      );
      final r = t.translate(p, from: ubuntu, to: windows);
      expect(r.path, r'C:\src\app');
    });

    test('WSL -> Windows non-mnt path becomes a UNC path', () {
      const p = EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/app',
      );
      final r = t.translate(p, from: ubuntu, to: windows);
      expect(r.path, r'\\wsl.localhost\Ubuntu\home\me\app');
    });

    test('Windows UNC path -> WSL for the matching distro', () {
      const p = EnvironmentPath(
        environmentId: 'windows',
        path: r'\\wsl.localhost\Ubuntu\home\me',
      );
      final r = t.translate(p, from: windows, to: ubuntu);
      expect(r.path, '/home/me');
    });

    test('translation between two WSL distros is not defined', () {
      final debian = wslEnv(id: 'wsl:Debian', distro: 'Debian');
      const p = EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me');
      expect(
        () => t.translate(p, from: ubuntu, to: debian),
        throwsA(isA<PathTranslationException>()),
      );
    });
  });
}
