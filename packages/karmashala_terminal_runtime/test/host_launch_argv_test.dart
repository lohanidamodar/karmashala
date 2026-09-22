import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_host/karmashala_host.dart' show windowsCommandLine;
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:karmashala_terminal_runtime/launch.dart';

/// What the session host builds for a pane's launch on Windows, set against
/// what `flutter_pty` builds for the same launch — the PTY path the owner has
/// run for months. The two spawners differ (the host starts argv[0] once and
/// quotes by `CommandLineToArgvW` rules; `flutter_pty` repeats the executable
/// and quotes nothing), so the assertion is on the command line each hands
/// `CreateProcessW`, which is what the child actually reads.
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
  }) => ptyLaunchFor(
    profile,
    context: LaunchContext.forProfile(profile, hostIsWindows: true),
    workingDirectory: cwd,
    shellIntegration: integrate,
  );

  /// The command line `flutter_pty` writes for [launch] (see
  /// `pty_command_line_test.dart`): the executable, repeated unless the launch
  /// says otherwise, then its arguments joined by single spaces.
  String flutterPtyLine(PtyLaunch launch) {
    final start = flutterPtyStartFor(launch, hostIsWindows: true);
    return [
      launch.executable,
      if (start.repeatExecutable) launch.executable,
      ...start.arguments,
    ].join(' ');
  }

  test(
    'the integrated PowerShell bootstrap arrives exactly as on the PTY path',
    () {
      final launch = launchFor(powerShell, integrate: true);

      expect(launch.hostArgv, [
        'powershell.exe',
        '-NoLogo',
        '-NoExit',
        '-Command',
        powerShellIntegrationScript(),
      ], reason: 'one plain -Command, never an encoded one');
      expect(
        windowsCommandLine(launch.hostArgv),
        flutterPtyLine(launch),
        reason:
            'the host must hand PowerShell the very command line flutter_pty '
            'does; quoting every token was a different one',
      );
    },
  );

  test(
    'a WSL pane goes to wsl.exe directly, and it reads what cmd.exe passed on',
    () {
      final launch = launchFor(ubuntu, cwd: r'C:\src\space dir');
      const cmd = 'cmd.exe cmd.exe /c ';
      final ptyLine = flutterPtyLine(launch);
      expect(ptyLine, startsWith(cmd));

      expect(launch.hostArgv, [
        'wsl.exe',
        '-d',
        'Ubuntu',
        '--cd',
        r'C:\src\space dir',
      ]);
      // `cmd.exe /c <line>` runs <line>: what wsl.exe reads on the PTY path is
      // exactly the tail, and it is exactly what the host now writes.
      expect(
        windowsCommandLine(launch.hostArgv),
        ptyLine.substring(cmd.length),
      );
    },
  );

  test(
    'the integrated WSL bootstrap arrives as the PTY path hands it over',
    () {
      final launch = launchFor(ubuntu, integrate: true, cwd: r'C:\repo');
      const cmd = 'cmd.exe cmd.exe /c ';

      expect(launch.hostArgv.first, 'wsl.exe');
      expect(launch.hostArgv, containsAllInOrder(['--', 'eval']));
      expect(
        windowsCommandLine(launch.hostArgv),
        flutterPtyLine(launch).substring(cmd.length),
      );
      // What the PTY path spawns is untouched by any of this.
      expect(launch.executable, 'cmd.exe');
      expect(launch.arguments.first, '/c');
    },
  );

  test('a WSL agent launch goes direct as well', () {
    final launch = agentPtyLaunchFor(
      const AgentPaneLaunch(
        agentId: 'claudeCode',
        executable: 'claude',
        wslDistribution: 'Ubuntu',
      ),
      context: const LaunchContext.wsl('Ubuntu'),
    );
    expect(launch.hostArgv.take(3), ['wsl.exe', '-d', 'Ubuntu']);
  });

  test('launches with no flutter_pty workaround are sent as they are', () {
    final plain = launchFor(powerShell);
    expect(plain.hostArgv, ['powershell.exe', '-NoLogo']);

    const cmdProfile = TerminalProfile(
      id: 'cmd',
      label: 'Command Prompt',
      shell: TerminalShell.commandPrompt,
    );
    expect(launchFor(cmdProfile).hostArgv, ['cmd.exe']);

    // A named cmd.exe is kept for what it does: finding a `.cmd` shim.
    final agent = agentPtyLaunchFor(
      const AgentPaneLaunch(agentId: 'claudeCode', executable: 'claude'),
      context: const LaunchContext.commandPrompt(),
    );
    expect(agent.directArgv, isNull);
    expect(agent.hostArgv.first, 'cmd.exe');
  });
}
