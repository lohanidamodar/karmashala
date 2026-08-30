import '../domain/agent_pane_launch.dart';
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
    this.environment = const {},
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Extra variables layered over the host environment for this child only.
  /// Empty for a plain shell; an agent pane uses it to tell the agent which
  /// session it is running in.
  final Map<String, String> environment;

  @override
  bool operator ==(Object other) =>
      other is PtyLaunch &&
      other.executable == executable &&
      other.workingDirectory == workingDirectory &&
      _mapEquals(other.environment, environment) &&
      _listEquals(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(
    executable,
    workingDirectory,
    Object.hashAll(arguments),
    Object.hashAllUnordered(
      environment.entries.map((e) => '${e.key}=${e.value}'),
    ),
  );

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

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

/// Builds the ConPTY launch that runs an agent CLI in a pane.
///
/// A WSL launch is wrapped exactly the way the external-terminal path wraps it
/// (`wsl.exe -d <distro> --cd <cwd> -- <exe> <args…>`), so an agent started in a
/// pane and the same agent started in Windows Terminal are the same command
/// line. On a non-Windows host ([onWindowsHost] false — the app running under
/// Linux/macOS) there is nothing to wrap: we are already in the target shell.
///
/// The session id is stamped into the child's environment rather than passed as
/// an argument, because it has to reach a *grandchild* — the MCP bridge the
/// agent spawns — and an argument would not. For WSL that also means naming the
/// variable in `WSLENV`, which is the only way a Win32 variable crosses into the
/// distro.
PtyLaunch agentPtyLaunchFor(
  AgentPaneLaunch launch, {
  bool onWindowsHost = true,
}) {
  final environment = <String, String>{
    if (launch.sessionId != null)
      kSessionIdEnvironmentVariable: launch.sessionId!,
  };
  final distro = launch.wslDistribution;
  if (distro == null || distro.isEmpty || !onWindowsHost) {
    return PtyLaunch(
      executable: launch.executable,
      arguments: launch.arguments,
      workingDirectory: launch.workingDirectory,
      environment: environment,
    );
  }
  return PtyLaunch(
    executable: 'wsl.exe',
    arguments: [
      '-d',
      distro,
      if (launch.workingDirectory != null) ...[
        '--cd',
        launch.workingDirectory!,
      ],
      '--',
      launch.executable,
      ...launch.arguments,
    ],
    // wsl.exe sets the child's directory itself, so the host process must not
    // also be pointed at a Linux path it cannot resolve.
    environment: {
      ...environment,
      if (launch.sessionId != null)
        'WSLENV': '$kSessionIdEnvironmentVariable/u',
    },
  );
}
