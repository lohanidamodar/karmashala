import 'package:karmashala_launch/karmashala_launch.dart';
import 'package:test/test.dart';

/// `terminalLaunchFor` decides with the OS it is told — the server's — never
/// the one the test (or a client) runs on.
void main() {
  const ubuntu = TerminalProfile(
    id: 'wsl:Ubuntu',
    label: 'Ubuntu (WSL)',
    shell: TerminalShell.wsl,
    wslDistribution: 'Ubuntu',
  );

  test('a POSIX server opens the profile\'s own shell in the folder', () {
    final built = terminalLaunchFor(
      profile: TerminalProfile.posix('/bin/zsh'),
      workingDirectory: '/src/app',
      hostIsWindows: false,
      shellIntegration: true,
      overlay: const {'API_TOKEN': 'x'},
    );
    expect(built.launch.hostArgv, ['/bin/zsh']);
    expect(built.launch.workingDirectory, '/src/app');
    expect(built.launch.environment, {'API_TOKEN': 'x'});
    expect(built.title, 'zsh');
    expect(built.profileId, 'posix:/bin/zsh');
    expect(
      built.shellIntegration,
      isFalse,
      reason: 'a POSIX login shell carries no bootstrap, so no markers',
    );
  });

  test('a Windows server reaches WSL through wsl.exe, integrated', () {
    final built = terminalLaunchFor(
      profile: ubuntu,
      workingDirectory: '/home/me',
      hostIsWindows: true,
      shellIntegration: true,
      overlay: const {'API_TOKEN': 'x'},
    );
    expect(built.launch.hostArgv.take(5), [
      'wsl.exe',
      '-d',
      'Ubuntu',
      '--cd',
      '/home/me',
    ]);
    expect(built.launch.hostArgv, containsAllInOrder(['--', 'eval']));
    expect(
      built.launch.workingDirectory,
      isNull,
      reason: 'a Linux folder is --cd, never a Windows process directory',
    );
    expect(built.launch.environment['WSLENV'], 'API_TOKEN/u');
    expect(built.shellIntegration, isTrue);
  });

  test('cmd.exe never gets integration, whatever the setting', () {
    final built = terminalLaunchFor(
      profile: TerminalProfile.commandPrompt,
      hostIsWindows: true,
      shellIntegration: true,
    );
    expect(built.launch.hostArgv, ['cmd.exe']);
    expect(built.shellIntegration, isFalse);
  });

  test('an agent launch carries its session id over the vault', () {
    final built = terminalLaunchFor(
      profile: TerminalProfile.powerShell,
      agentLaunch: const AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        arguments: ['--resume', 'abc'],
        workingDirectory: '/src/app',
        sessionId: 's1',
        title: 'Fix it',
        environment: {'DISABLE_AUTOUPDATER': '1'},
        removedEnvironment: {'ANTHROPIC_API_KEY'},
      ),
      hostIsWindows: false,
      shellIntegration: true,
      overlay: const {kSessionIdEnvironmentVariable: 'forged', 'K': 'v'},
    );
    expect(built.launch.hostArgv, ['claude', '--resume', 'abc']);
    expect(built.launch.workingDirectory, '/src/app');
    expect(built.launch.environment, {
      kSessionIdEnvironmentVariable: 's1',
      kSessionPortBaseEnvironmentVariable: '${sessionPortBase('s1')}',
      'K': 'v',
      'DISABLE_AUTOUPDATER': '1',
    });
    expect(built.launch.removedEnvironment, {'ANTHROPIC_API_KEY'});
    expect(built.title, 'Fix it');
    expect(built.profileId, 'agent:claudeCode');
    expect(built.shellIntegration, isFalse);
  });

  test('a WSL agent on a Windows server goes to wsl.exe directly', () {
    final built = terminalLaunchFor(
      profile: TerminalProfile.powerShell,
      agentLaunch: const AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        wslDistribution: 'Ubuntu',
        sessionId: 's1',
      ),
      hostIsWindows: true,
    );
    expect(built.launch.hostArgv.take(3), ['wsl.exe', '-d', 'Ubuntu']);
    expect(
      built.launch.environment['WSLENV'],
      contains('$kSessionIdEnvironmentVariable/u'),
    );
  });

  test('the same WSL agent on a POSIX server runs inside, unwrapped', () {
    final built = terminalLaunchFor(
      profile: TerminalProfile.powerShell,
      agentLaunch: const AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        wslDistribution: 'Ubuntu',
      ),
      hostIsWindows: false,
    );
    expect(built.launch.hostArgv, ['claude']);
  });
}
