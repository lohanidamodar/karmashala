import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/core/process/wsl_command_runner.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildWslInvocation', () {
    test('wraps a simple command for a distribution', () {
      final inv = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(executable: 'git', arguments: ['status']),
      );
      expect(inv.executable, 'wsl.exe');
      expect(inv.arguments, ['-d', 'Ubuntu', '--', 'git', 'status']);
    });

    test('passes the working directory via --cd', () {
      final inv = buildWslInvocation(
        'Ubuntu',
        const CommandRequest(
          executable: 'ls',
          arguments: ['-la'],
          workingDirectory: EnvironmentPath(
            environmentId: 'wsl:Ubuntu',
            path: '/home/me/app',
          ),
        ),
      );
      expect(inv.arguments, [
        '-d',
        'Ubuntu',
        '--cd',
        '/home/me/app',
        '--',
        'ls',
        '-la',
      ]);
    });

    test('runner exposes its environment id', () {
      const runner = WslCommandRunner(
        environmentId: 'wsl:Ubuntu',
        distribution: 'Ubuntu',
      );
      expect(runner.environmentId, 'wsl:Ubuntu');
    });
  });
}
