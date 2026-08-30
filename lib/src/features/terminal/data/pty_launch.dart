import '../domain/shell_integration.dart';
import '../domain/terminal_profile.dart';

/// A concrete process launch for a host ConPTY: which executable, its arguments,
/// and the host working directory (when the shell itself sets the cwd).
///
/// Pure and testable — separated from the actual [Pty] spawn so the
/// shell-selection logic can be unit-tested without a process.
class PtyLaunch {
  const PtyLaunch({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  @override
  bool operator ==(Object other) =>
      other is PtyLaunch &&
      other.executable == executable &&
      other.workingDirectory == workingDirectory &&
      _listEquals(other.arguments, arguments);

  @override
  int get hashCode =>
      Object.hash(executable, workingDirectory, Object.hashAll(arguments));

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Builds the ConPTY launch for [profile].
///
/// Windows-host shells receive [workingDirectory] directly. A WSL profile is
/// launched via `wsl.exe -d <distro>`; the working directory is handed to WSL
/// with `--cd` (it accepts a Windows path and translates it) rather than set on
/// the host process.
///
/// [shellIntegration] adds OSC 133 command markers for the shells that support
/// it. It defaults to `false` and, when false, every launch is byte-identical to
/// what shipped before shell integration existed — a shell that cannot be
/// integrated must behave exactly as it always did.
PtyLaunch ptyLaunchFor(
  TerminalProfile profile, {
  String? workingDirectory,
  bool shellIntegration = false,
}) {
  final integrate = shellIntegration && shellSupportsIntegration(profile.shell);
  switch (profile.shell) {
    case TerminalShell.powerShell:
      return PtyLaunch(
        executable: 'powershell.exe',
        arguments: [
          '-NoLogo',
          // -NoExit keeps the session interactive after the bootstrap runs;
          // -EncodedCommand sidesteps Windows command-line quoting entirely.
          if (integrate) ...[
            '-NoExit',
            '-EncodedCommand',
            encodePowerShellCommand(powerShellIntegrationScript()),
          ],
        ],
        workingDirectory: workingDirectory,
      );
    case TerminalShell.commandPrompt:
      return PtyLaunch(
        executable: 'cmd.exe',
        workingDirectory: workingDirectory,
      );
    case TerminalShell.wsl:
      final distro = profile.wslDistribution ?? '';
      return PtyLaunch(
        executable: 'wsl.exe',
        arguments: [
          '-d',
          distro,
          if (workingDirectory != null) ...['--cd', workingDirectory],
        ],
      );
  }
}
