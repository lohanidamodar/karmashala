import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/pty_launch.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';

/// The command line `flutter_pty` 0.4.2 really hands to `CreateProcessW`.
///
/// Its `build_command` (`src/flutter_pty_win.c`) writes the executable and then
/// every entry of `argv`, and `flutter_pty.dart` has already put the executable
/// at `argv[0]` — so the executable is written **twice**, and the arguments are
/// concatenated with single spaces and no quoting of their own.
///
/// Asserting on this string rather than on [PtyLaunch]'s fields is the whole
/// point of this file: the fields looked correct all along, and the bug was
/// only ever visible in what the tokens mean once they reach the child.
String conPtyCommandLine(PtyLaunch launch) =>
    [launch.executable, launch.executable, ...launch.arguments].join(' ');

const _ubuntu = TerminalProfile(
  id: 'wsl:Ubuntu',
  label: 'Ubuntu (WSL)',
  shell: TerminalShell.wsl,
  wslDistribution: 'Ubuntu',
);

void main() {
  group('the command line a WSL pane really gets', () {
    // Each of these was run for real, as a command line, on Windows
    // 10.0.26200 against the `archlinux` distribution. The old form is kept
    // beside the new one because the difference is the bug.
    test('goes through cmd.exe, so wsl.exe sees its own options', () {
      final launch = ptyLaunchFor(_ubuntu, workingDirectory: r'C:\repo');

      expect(
        conPtyCommandLine(launch),
        r'cmd.exe cmd.exe /c wsl.exe -d Ubuntu --cd C:\repo',
        reason:
            'cmd.exe drops the stray leading token and re-parses; `wsl.exe '
            'wsl.exe -d …` instead made the second token the command to run '
            'inside the distro',
      );
      // The pane's process is cmd.exe now, which is also what the controller
      // asks this builder for when it decides which OSC title to refuse.
      expect(launch.executable, 'cmd.exe');
      // wsl.exe sets the child's directory with --cd; the host process must not
      // also be pointed at a path Windows may not be able to resolve.
      expect(launch.workingDirectory, isNull);
    });

    test('a working directory with a space stays one argument', () {
      final launch = ptyLaunchFor(
        _ubuntu,
        workingDirectory: r'C:\src\space dir',
      );
      expect(
        conPtyCommandLine(launch),
        r'cmd.exe cmd.exe /c wsl.exe -d Ubuntu --cd "C:\src\space dir"',
      );
    });

    test('a Linux working directory is passed through untouched', () {
      final launch = ptyLaunchFor(_ubuntu, workingDirectory: '/home/me/app');
      expect(
        conPtyCommandLine(launch),
        'cmd.exe cmd.exe /c wsl.exe -d Ubuntu --cd /home/me/app',
      );
    });

    test('no working directory means no --cd at all', () {
      expect(
        conPtyCommandLine(ptyLaunchFor(_ubuntu)),
        'cmd.exe cmd.exe /c wsl.exe -d Ubuntu',
      );
    });

    test('shell integration does not reach a WSL pane', () {
      // OSC 133 markers come from a shell's prompt hooks and this app only
      // knows how to install PowerShell's, so the line must be identical.
      expect(
        conPtyCommandLine(ptyLaunchFor(_ubuntu, shellIntegration: true)),
        conPtyCommandLine(ptyLaunchFor(_ubuntu)),
      );
    });
  });

  group('the command line the other Windows panes really get', () {
    // Neither is changed here. Both are pinned because the WSL fix is a change
    // to the *shape* every Windows branch shares, and the one thing worse than
    // this bug would be quietly re-shaping the default profile with it.
    test('a cmd.exe pane needs no wrapper', () {
      // Measured: `cmd.exe cmd.exe` starts exactly one shell — one banner, one
      // prompt, one process — because cmd discards the stray token.
      expect(
        conPtyCommandLine(ptyLaunchFor(TerminalProfile.commandPrompt)),
        'cmd.exe cmd.exe',
      );
      expect(ptyLaunchFor(TerminalProfile.commandPrompt).arguments, isEmpty);
    });

    test('a PowerShell pane is still nested, knowingly', () {
      // Measured: two `powershell.exe` processes. PowerShell's first
      // positional parameter is `-Command`, so the duplicate binds to it and
      // `-NoLogo` ends up inside the command string rather than applied to the
      // outer shell. It works — the inner shell is the interactive one — and
      // fixing it is [throughCommandPrompt], not something to slip in here.
      expect(
        conPtyCommandLine(ptyLaunchFor(TerminalProfile.powerShell)),
        'powershell.exe powershell.exe -NoLogo',
      );
    });

    test('the PowerShell integration bootstrap is unchanged', () {
      final launch = ptyLaunchFor(
        TerminalProfile.powerShell,
        shellIntegration: true,
      );
      expect(launch.executable, 'powershell.exe');
      expect(
        launch.arguments.take(3),
        ['-NoLogo', '-NoExit', '-EncodedCommand'],
      );
    });
  });

  group('throughCommandPrompt', () {
    test('quotes only what a re-parse would otherwise split', () {
      expect(
        throughCommandPrompt(['a.exe', 'plain', 'two words']).arguments,
        ['/c', 'a.exe plain "two words"'],
      );
    });

    test('carries the working directory and environment through', () {
      final launch = throughCommandPrompt(
        ['a.exe'],
        workingDirectory: r'C:\ws',
        environment: const {'K': 'v'},
      );
      expect(launch.workingDirectory, r'C:\ws');
      expect(launch.environment, {'K': 'v'});
    });
  });
}
