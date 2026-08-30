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
        // Quoted for the same reason: a repository under a path containing a
        // space used to split into two arguments, and the pane opened somewhere
        // else or not at all. A path without a space is unchanged.
        arguments: [
          '-d',
          distro,
          if (workingDirectory != null) ...['--cd', workingDirectory],
        ].map(quoteWindowsCommandArgument).toList(),
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
  if (!onWindowsHost) {
    return PtyLaunch(
      executable: launch.executable,
      arguments: launch.arguments,
      workingDirectory: launch.workingDirectory,
      environment: environment,
    );
  }
  if (distro == null || distro.isEmpty) {
    // A Windows-native agent is launched **through `cmd.exe /c`**, not directly.
    //
    // `flutter_pty` 0.4.2 builds its Windows command line as
    // `<exe> <argv…>` while the Dart side has already put the executable at
    // `argv[0]`, so the child is always handed **its own executable name as its
    // first argument**. Loop 38 found this as `powershell.exe powershell.exe`
    // spawning a nested shell; for an agent CLI it is worse, because the first
    // positional argument is the *prompt*: `codex.exe` starts a turn asking
    // about "codex.exe". The same function also concatenates arguments with
    // single spaces and no quoting, so any argument containing a space is split
    // — verified by a real `codex.exe` launch rejecting `say` as an unexpected
    // argument.
    //
    // `cmd.exe` ignores the duplicated leading token and re-parses the rest, so
    // one `/c` argument carrying a correctly quoted command line fixes both.
    // PowerShell cannot be used for this: its first positional parameter is
    // `-Command`, which the duplicate would bind to.
    return PtyLaunch(
      executable: 'cmd.exe',
      arguments: [
        '/c',
        [
          launch.executable,
          ...launch.arguments,
        ].map(quoteWindowsCommandArgument).join(' '),
      ],
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
      // Quoted for the same reason the native branch goes through `cmd.exe`:
      // `flutter_pty` concatenates arguments with single spaces and no quoting,
      // so an unquoted multi-word prompt reaches the agent as several
      // arguments and is silently ignored. There is no wrapper on this path to
      // re-parse the line — `wsl.exe`'s argv comes straight from
      // `CommandLineToArgvW` — so the quoting has to be in the strings. An
      // argument with no whitespace passes through unchanged.
    ].map(quoteWindowsCommandArgument).toList(),
    // wsl.exe sets the child's directory itself, so the host process must not
    // also be pointed at a Linux path it cannot resolve.
    environment: {
      ...environment,
      if (launch.sessionId != null)
        'WSLENV': '$kSessionIdEnvironmentVariable/u',
    },
  );
}

/// Quotes one argument for a command line `cmd.exe` will re-parse.
///
/// Follows `CommandLineToArgvW`'s rules — wrap in double quotes when the value
/// contains whitespace or a quote, escape embedded quotes, and double the
/// backslashes that immediately precede one — because that is what the agent's
/// own argument parser will apply on the other side.
///
/// **One thing it deliberately does not do:** escape `%`. `cmd.exe` expands
/// `%NAME%` for variables that exist, and there is no reliable escape for it on
/// a `/c` command line (`%%` is a batch-file convention and is not collapsed
/// here). A prompt containing `%USERNAME%` will therefore arrive substituted on
/// a Windows-native launch. Unknown names are left alone, and the WSL path —
/// which does not go through `cmd` — is unaffected.
String quoteWindowsCommandArgument(String value) {
  if (value.isNotEmpty && !value.contains(RegExp(r'[ \t"]'))) return value;

  final out = StringBuffer('"');
  var backslashes = 0;
  for (final unit in value.codeUnits) {
    if (unit == 0x5C) {
      backslashes++;
      continue;
    }
    if (unit == 0x22) {
      // Every backslash immediately before a quote must be doubled, then the
      // quote itself escaped.
      out.write('\\' * (backslashes * 2 + 1));
      out.write('"');
      backslashes = 0;
      continue;
    }
    out.write('\\' * backslashes);
    backslashes = 0;
    out.writeCharCode(unit);
  }
  // Trailing backslashes would otherwise escape the closing quote.
  out
    ..write('\\' * (backslashes * 2))
    ..write('"');
  return out.toString();
}
