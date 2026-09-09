import 'package:agent_cli/src/process/command_runner.dart';
import 'package:agent_cli/src/process/wsl_command_runner.dart';
import 'package:agent_cli/src/environments/environment_path.dart';
import 'package:test/test.dart';

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
