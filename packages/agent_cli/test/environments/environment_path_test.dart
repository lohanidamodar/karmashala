import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:test/test.dart';

void main() {
  group('EnvironmentPath', () {
    test('equal only when both environment and path match', () {
      const a = EnvironmentPath(environmentId: 'windows', path: r'C:\x');
      const b = EnvironmentPath(environmentId: 'windows', path: r'C:\x');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('same textual path in different environments is NOT equal', () {
      const win = EnvironmentPath(environmentId: 'windows', path: '/work');
      const wsl = EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/work');
      expect(win == wsl, isFalse);
    });

    test('different paths in the same environment are not equal', () {
      const a = EnvironmentPath(environmentId: 'windows', path: r'C:\a');
      const b = EnvironmentPath(environmentId: 'windows', path: r'C:\b');
      expect(a == b, isFalse);
    });
  });
}
