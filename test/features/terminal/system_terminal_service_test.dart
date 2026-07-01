import 'package:chitragupta/src/core/process/command_runner.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/settings/domain/permission_mode.dart';
import 'package:chitragupta/src/features/terminal/data/system_terminal_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

void main() {
  group('resumeCommandLine', () {
    final cwd = EnvironmentPath(environmentId: 'windows', path: r'C:\ws\app');

    test('Claude on the Windows host resumes by id (ask adds no flags)', () {
      final cmd = resumeCommandLine(
        agentExecutable: 'claude',
        cli: 'claudeCode',
        externalId: 'abc',
        environment: windowsEnv(),
        cwd: cwd,
      );
      expect(cmd, ['claude', '--resume', 'abc']);
    });

    test('Claude bypass adds --permission-mode bypassPermissions', () {
      final cmd = resumeCommandLine(
        agentExecutable: 'claude',
        cli: 'claudeCode',
        externalId: 'abc',
        environment: windowsEnv(),
        cwd: cwd,
        permissionMode: PermissionMode.bypass,
      );
      expect(cmd, [
        'claude',
        '--permission-mode',
        'bypassPermissions',
        '--resume',
        'abc',
      ]);
    });

    test('a WSL session is wrapped in wsl.exe with --cd (codex ask flag)', () {
      final cmd = resumeCommandLine(
        agentExecutable: 'codex',
        cli: 'codex',
        externalId: 'sid',
        environment: wslEnv(distro: 'Ubuntu'),
        cwd: EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
      );
      expect(cmd, [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        '/home/me/app',
        '--',
        'codex',
        '--ask-for-approval',
        'on-request',
        'resume',
        'sid',
      ]);
    });
  });

  group('SystemTerminalService.launch', () {
    test('Windows Terminal opens at -d <cwd> and runs the command', () async {
      final runner = FakeCommandRunner();
      final service = SystemTerminalService(runner);

      await service.launch(
        const SystemTerminal(
          kind: SystemTerminalKind.windowsTerminal,
          label: 'Windows Terminal',
          executable: 'wt.exe',
        ),
        command: ['claude', '--resume', 'abc'],
        workingDirectory: r'C:\ws\app',
      );

      expect(runner.startRequests.single.executable, 'wt.exe');
      expect(runner.startRequests.single.arguments, [
        '-w',
        '0',
        'new-tab',
        '-d',
        r'C:\ws\app',
        'claude',
        '--resume',
        'abc',
      ]);
    });

    test('available() returns terminals found on PATH', () async {
      final runner = FakeCommandRunner(
        responder: (req) => CommandResult(
          exitCode: req.arguments.first == 'wt.exe' ? 0 : 1,
          stdout: '',
          stderr: '',
        ),
      );
      final service = SystemTerminalService(runner);

      final found = await service.available();
      expect(found.map((t) => t.executable), contains('wt.exe'));
      expect(found.map((t) => t.executable), isNot(contains('wezterm.exe')));
    });

    test(
      'PowerShell safely quotes executable, arguments, and working dir',
      () async {
        final runner = FakeCommandRunner();
        final service = SystemTerminalService(runner);

        await service.launch(
          const SystemTerminal(
            kind: SystemTerminalKind.powerShell,
            label: 'PowerShell',
            executable: 'powershell.exe',
          ),
          command: [r'C:\Program Files\Claude\claude.exe', '--resume', 'a b'],
          workingDirectory: r"C:\work\owner's app",
        );

        expect(
          runner.startRequests.single.arguments.last,
          "Set-Location -LiteralPath 'C:\\work\\owner''s app'; "
          "& 'C:\\Program Files\\Claude\\claude.exe' '--resume' 'a b'",
        );
      },
    );
  });
}
