import 'package:karmashala_host/karmashala_host.dart' show windowsCommandLine;
import 'package:karmashala_launch/karmashala_launch.dart';
import 'package:test/test.dart';

/// The command line the server's ConPTY writes for a pane's launch on
/// Windows: argv[0] started once, every token quoted by `CommandLineToArgvW`
/// rules — `windowsCommandLine` is what `CreateProcessW` is handed, so the
/// assertion is on what the child actually reads.
void main() {
  const powerShell = TerminalProfile(
    id: 'powershell',
    label: 'Windows PowerShell',
    shell: TerminalShell.powerShell,
  );
  const ubuntu = TerminalProfile(
    id: 'wsl:Ubuntu',
    label: 'Ubuntu (WSL)',
    shell: TerminalShell.wsl,
    wslDistribution: 'Ubuntu',
  );

  PtyLaunch launchFor(
    TerminalProfile profile, {
    bool integrate = false,
    String? cwd,
  }) => terminalLaunchFor(
    profile: profile,
    hostIsWindows: true,
    workingDirectory: cwd,
    shellIntegration: integrate,
  ).launch;

  test('the integrated PowerShell bootstrap is one plain -Command', () {
    final launch = launchFor(powerShell, integrate: true);
    expect(launch.hostArgv, [
      'powershell.exe',
      '-NoLogo',
      '-NoExit',
      '-Command',
      powerShellIntegrationScript(),
    ]);
    final line = windowsCommandLine(launch.hostArgv);
    expect(line, startsWith('powershell.exe -NoLogo -NoExit -Command "'));
    expect(line, isNot(contains('EncodedCommand')));
  });

  test('a WSL pane goes to wsl.exe directly, its folder one argument', () {
    final launch = launchFor(ubuntu, cwd: '/home/me/space dir');
    expect(
      windowsCommandLine(launch.hostArgv),
      'wsl.exe -d Ubuntu --cd "/home/me/space dir"',
    );
    expect(launch.workingDirectory, isNull);
  });

  test('the integrated WSL bootstrap is a single encoded token', () {
    final launch = launchFor(ubuntu, integrate: true, cwd: '/repo');
    final line = windowsCommandLine(launch.hostArgv);
    expect(line, startsWith('wsl.exe -d Ubuntu --cd /repo -- eval "'));
    expect(
      line.length,
      lessThan(32767),
      reason: 'CreateProcessW takes at most 32767 characters',
    );
  });

  test('launches that need no wrapper are sent as they are', () {
    expect(launchFor(powerShell).hostArgv, ['powershell.exe', '-NoLogo']);
    expect(launchFor(TerminalProfile.commandPrompt).hostArgv, ['cmd.exe']);
    // A named cmd.exe is kept for what it does: finding a `.cmd` shim.
    final agent = agentPtyLaunchFor(
      const AgentPaneLaunch(agentId: 'claudeCode', executable: 'claude'),
      context: const LaunchContext.commandPrompt(),
    );
    expect(agent.directArgv, isNull);
    expect(agent.hostArgv.first, 'cmd.exe');
  });
}
