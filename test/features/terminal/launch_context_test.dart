import 'package:karmashala_terminal_runtime/launch.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the context is the destination, not the host', () {
    const wslLaunch = AgentPaneLaunch(
      agentId: 'claudeCode',
      executable: 'claude',
      wslDistribution: 'Ubuntu',
    );

    test('the same launch resolves differently on each host', () {
      expect(
        LaunchContext.forAgent(wslLaunch, hostIsWindows: true).kind,
        ShellContextKind.wsl,
      );
      // Same launch, but we are already in the distro: nothing to cross.
      expect(
        LaunchContext.forAgent(wslLaunch, hostIsWindows: false).kind,
        ShellContextKind.posix,
      );
    });

    test('an empty distribution is not a WSL destination', () {
      const launch = AgentPaneLaunch(
        agentId: 'x',
        executable: 'x',
        wslDistribution: '',
      );
      expect(
        LaunchContext.forAgent(launch, hostIsWindows: true).kind,
        ShellContextKind.windowsNative,
      );
    });

    test('only a Windows-host context can reach the Windows executables', () {
      expect(const LaunchContext.wsl('Ubuntu').needsWrapper, isTrue);
      expect(const LaunchContext.commandPrompt().needsWrapper, isTrue);
      expect(const LaunchContext.powerShell().needsWrapper, isTrue);
      expect(const LaunchContext.posix().needsWrapper, isFalse);
      expect(const LaunchContext.insideWsl('Ubuntu').needsWrapper, isFalse);
      expect(const LaunchContext.insideWsl('Ubuntu').isWindowsHost, isFalse);
    });

    test('an environment resolves to the crossing it needs', () {
      expect(LaunchContext.forEnvironment('Ubuntu').kind, ShellContextKind.wsl);
      expect(
        LaunchContext.forEnvironment(null).kind,
        ShellContextKind.windowsNative,
      );
    });
  });

  group('a shell profile opens into its context', () {
    test('a WSL profile on a Windows host runs wsl.exe through cmd.exe', () {
      const profile = TerminalProfile(
        id: 'wsl:Ubuntu',
        label: 'Ubuntu',
        shell: TerminalShell.wsl,
        wslDistribution: 'Ubuntu',
      );
      final launch = ptyLaunchFor(
        profile,
        context: LaunchContext.forProfile(profile, hostIsWindows: true),
        workingDirectory: r'C:\repo',
      );
      expect(launch.executable, 'cmd.exe');
      expect(launch.arguments, ['/c', r'wsl.exe -d Ubuntu --cd C:\repo']);
    });

    test('every profile on a POSIX host opens the login shell', () {
      // `powershell.exe`/`cmd.exe`/`wsl.exe` do not exist there, and we are
      // already in the shell the profile was standing in for.
      for (final profile in [
        TerminalProfile.powerShell,
        TerminalProfile.commandPrompt,
        const TerminalProfile(
          id: 'wsl:Ubuntu',
          label: 'Ubuntu',
          shell: TerminalShell.wsl,
          wslDistribution: 'Ubuntu',
        ),
      ]) {
        final launch = ptyLaunchFor(
          profile,
          context: LaunchContext.forProfile(
            profile,
            hostIsWindows: false,
            posixShell: '/usr/bin/zsh',
          ),
          workingDirectory: '/home/u/repo',
        );
        expect(launch.executable, '/usr/bin/zsh');
        expect(launch.arguments, isEmpty);
        expect(launch.workingDirectory, '/home/u/repo');
      }
    });

    test('a POSIX host with no SHELL falls back to bash', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        context: LaunchContext.forProfile(
          TerminalProfile.powerShell,
          hostIsWindows: false,
        ),
      );
      expect(launch.executable, '/bin/bash');
    });

    test('omitting the context keeps the Windows-host reading', () {
      expect(
        ptyLaunchFor(TerminalProfile.powerShell).executable,
        'powershell.exe',
      );
      expect(ptyLaunchFor(TerminalProfile.commandPrompt).executable, 'cmd.exe');
    });
  });
}
