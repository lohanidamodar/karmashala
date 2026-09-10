import 'dart:convert';

import '../domain/agent_pane_launch.dart';
import '../domain/launch_context.dart';
import '../domain/shell_integration.dart';
import '../domain/wsl_shell_integration.dart';
import '../domain/terminal_profile.dart';

/// A concrete process launch for a host ConPTY: which executable, its
/// arguments, and the host working directory.
///
/// Deliberately not a [ShellCommand] and with no route back to one, which is
/// what makes double-wrapping impossible rather than merely discouraged.
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

  /// Extra variables layered over the host environment for this child only —
  /// an agent pane uses it to tell the agent which session it is running in.
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

  /// Names the launch **without any environment value** — [environment] carries
  /// the user's secrets, and a test asserts no value appears here.
  @override
  String toString() =>
      'PtyLaunch($executable, ${arguments.length} argument(s), '
      '${environment.length} environment variable(s))';

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

/// Builds the ConPTY launch for [profile], in the shell context it will open
/// into.
///
/// A WSL profile goes through `cmd.exe /c wsl.exe -d <distro>` (see
/// [throughCommandPrompt]) and takes its directory from `--cd`, which accepts a
/// Windows path; a POSIX [context] opens the login shell instead. With
/// [shellIntegration] false every launch is byte-identical to what shipped
/// before shell integration existed.
PtyLaunch ptyLaunchFor(
  TerminalProfile profile, {
  LaunchContext? context,
  String? workingDirectory,
  bool shellIntegration = false,
  Map<String, String> environment = const {},
}) {
  final target =
      context ?? LaunchContext.forProfile(profile, hostIsWindows: true);
  final integrate = shellIntegration && shellSupportsIntegration(profile.shell);
  switch (target.kind) {
    case ShellContextKind.posix:
      // Already in the target shell — `wsl.exe`/`powershell.exe` don't exist —
      // so just open the login shell in the working directory.
      return PtyLaunch(
        executable: target.posixShell ?? '/bin/bash',
        workingDirectory: workingDirectory,
        environment: environment,
      );
    case ShellContextKind.powerShell:
      // Still spawned directly, and still *nested* because of it: the
      // duplicate token [throughCommandPrompt] describes binds to PowerShell's
      // positional `-Command`, so two powershell.exe processes start. It works
      // — the inner shell is the one the user types into — so it is left as it
      // shipped.
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
        environment: environment,
      );
    // A shell profile never names a bare executable; the Windows-native shell
    // is `cmd.exe`, so both spellings land here.
    case ShellContextKind.windowsNative:
    case ShellContextKind.commandPrompt:
      // Needs no wrapper: the duplication makes this `cmd.exe cmd.exe`, and
      // `cmd` discards the stray token — measured as one shell, one prompt.
      return PtyLaunch(
        executable: 'cmd.exe',
        workingDirectory: workingDirectory,
        environment: environment,
      );
    case ShellContextKind.wsl:
      // Through `cmd.exe /c` for the reason [throughCommandPrompt] documents:
      // spawned directly the line becomes `wsl.exe wsl.exe -d <distro> …`, and
      // `wsl.exe` reads that second token as the command to run inside the
      // distro — so the pane reached its shell only by having the login shell
      // exec a PE back out through interop, which dies when interop is off.
      final distro = target.wslDistribution ?? '';
      // Integrated, the pane's first command is the bootstrap, carried by the
      // same payload every agent launch already crosses on.
      if (integrate) {
        return wrapForPty(
          ShellCommand(
            executable: '/bin/sh',
            arguments: ['-c', wslIntegrationBootstrap()],
            workingDirectory: workingDirectory,
            environment: environment,
          ),
          target,
        );
      }
      // No host working directory: `wsl.exe` sets the child's own with `--cd`,
      // so `cmd.exe` is not pointed at a Linux path Windows cannot resolve.
      return throughCommandPrompt([
        'wsl.exe',
        '-d',
        distro,
        if (workingDirectory != null) ...['--cd', workingDirectory],
      ], environment: withWslEnv(environment));
  }
}

/// [environment] plus the `WSLENV` that makes it cross into a distribution: a
/// Win32 variable reaches a WSL child **only** if `WSLENV` names it.
///
/// `/u` on every name, never `/p` — a value that merely looks like a path would
/// be rewritten on the way in, silently. The names (not the values) are
/// readable inside the distro as `$WSLENV`. Returns [environment] unchanged
/// when it is empty.
Map<String, String> withWslEnv(Map<String, String> environment) {
  if (environment.isEmpty) return environment;
  return {
    ...environment,
    'WSLENV': environment.keys.map((k) => '$k/u').join(':'),
  };
}

/// One Windows command line, handed to `cmd.exe /c` so that `cmd` re-parses it.
///
/// **Every** ConPTY child is spawned as `<exe> <exe> <args…>` — `flutter_pty`
/// 0.4.2 writes the executable and then all of `argv`, which already starts
/// with it — and `cmd.exe` is the only wrapper that survives that, because it
/// discards the stray leading token and restores the quoting `build_command`
/// throws away. The price is `cmd`'s own `%NAME%` expansion.
PtyLaunch throughCommandPrompt(
  List<String> parts, {
  String? workingDirectory,
  Map<String, String> environment = const {},
}) => PtyLaunch(
  executable: 'cmd.exe',
  arguments: ['/c', parts.map(quoteWindowsCommandArgument).join(' ')],
  workingDirectory: workingDirectory,
  environment: environment,
);

/// Builds the ConPTY launch that runs an agent CLI in a pane, for the context
/// the command is actually going into.
///
/// The session id and its derived port base are stamped into the child's
/// *environment* rather than passed as arguments, because they have to reach a
/// grandchild — the MCP bridge the agent spawns. [environment] is the user's
/// own variables, layered **under** that plumbing so a user variable can never
/// displace it.
PtyLaunch agentPtyLaunchFor(
  AgentPaneLaunch launch, {
  LaunchContext? context,
  Map<String, String> environment = const {},
}) => wrapForPty(
      ShellCommand(
        executable: launch.executable,
        // `commandArguments`, not `arguments`: the MCP flags are rebuilt for
        // this start and sit beside the stored ones rather than inside them.
        arguments: launch.commandArguments,
        workingDirectory: launch.workingDirectory,
        environment: {
          ...environment,
          if (launch.sessionId != null) ...{
            kSessionIdEnvironmentVariable: launch.sessionId!,
            // Beside the id and through the same `WSLENV` plumbing. A
            // namespace a repository's scripts opt into, so two worktree
            // sessions running one script do not both bind the same port.
            kSessionPortBaseEnvironmentVariable: '${sessionPortBase(
              launch.sessionId!,
            )}',
          },
        },
      ),
      context ?? LaunchContext.forAgent(launch, hostIsWindows: true),
    );

/// The **one** place a command gets a wrapper put in front of it for a ConPTY.
/// It consumes a [ShellCommand] and returns a [PtyLaunch] with no route back,
/// so "wrap the wrapped launch again" is not a mistake that compiles.
PtyLaunch wrapForPty(ShellCommand command, LaunchContext context) {
  switch (context.kind) {
    case ShellContextKind.posix:
      // Already inside the target shell, so there is nothing to cross — in
      // particular a WSL-environment launch must NOT pick up `wsl.exe` here.
      return PtyLaunch(
        executable: command.executable,
        arguments: command.arguments,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
      );
    case ShellContextKind.windowsNative:
    case ShellContextKind.powerShell:
      // **PowerShell is the Windows-native shell for an agent**, not
      // `cmd.exe`, so a pane, its "copy command" line and an external terminal
      // all speak one shell. `-EncodedCommand` is what survives `flutter_pty`'s
      // unquoted `<exe> <argv…>` concatenation — one base64 token has nothing
      // to split — and it keeps `cmd`'s `%NAME%` expansion away from a prompt.
      final script =
          '& ${command.parts.map(quotePowerShellArgument).join(' ')}';
      return PtyLaunch(
        executable: 'powershell.exe',
        arguments: [
          '-NoLogo',
          '-NoProfile',
          '-EncodedCommand',
          encodePowerShellCommand(script),
        ],
        workingDirectory: command.workingDirectory,
        environment: command.environment,
      );
    case ShellContextKind.commandPrompt:
      // Only when the profile *names* `cmd.exe`: it ignores the duplicated
      // leading token and re-parses one correctly quoted `/c` line.
      return throughCommandPrompt(
        command.parts,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
      );
    case ShellContextKind.wsl:
      // **Through `cmd.exe /c`, carrying a base64 payload the distro's login
      // shell decodes.** `wsl.exe … -- <command>` is not an argv hand-off: WSL
      // runs the command-line *tail* through the login shell, so a line quoted
      // for Windows is parsed a second time under POSIX rules — a multi-line
      // prompt died as `zsh:1: unmatched` quote, and `$(…)` in a prompt really
      // executed. [encodedPosixShellCommand] is the POSIX `-EncodedCommand`:
      // its alphabet has nothing either parser rewrites. `--cd` stays on the
      // `cmd` line because `wsl.exe` is what translates a Windows path.
      return throughCommandPrompt(
        [
          'wsl.exe',
          '-d',
          context.wslDistribution ?? '',
          if (command.workingDirectory != null) ...[
            '--cd',
            command.workingDirectory!,
          ],
          '--',
          ...encodedPosixShellCommand(command.parts),
        ],
        // wsl.exe sets the child's directory itself, and a Win32 variable
        // only crosses into the distro if `WSLENV` names it.
        environment: withWslEnv(command.environment),
      );
  }
}

/// The same context decision, for a command handed to an **external** terminal
/// rather than a ConPTY.
///
/// Only the environment crossing belongs here; nothing is quoted for the
/// terminal's own shell, because those paths deliver argv properly. The WSL
/// crossing is not one of them — `wsl.exe … -- <command>` hands its tail to the
/// login shell — so the command goes through [encodedPosixShellCommand] here
/// too, and every consumer renders that token with Windows quoting, which is
/// exactly the double quote it needs.
List<String> wrapForExternalTerminal(
  ShellCommand command,
  LaunchContext context,
) {
  if (context.kind != ShellContextKind.wsl) return command.parts;
  return [
    'wsl.exe',
    '-d',
    context.wslDistribution ?? '',
    if (command.workingDirectory != null) ...[
      '--cd',
      command.workingDirectory!,
    ],
    '--',
    ...encodedPosixShellCommand(command.parts),
  ];
}

/// Quotes one argument for a PowerShell command line: single quotes, with an
/// embedded single quote doubled.
String quotePowerShellArgument(String value) =>
    "'${value.replaceAll("'", "''")}'";

/// Quotes one argument for a **POSIX** shell — `sh`, `bash`, `zsh`.
///
/// Single quotes, the one POSIX construct with no exceptions inside them, so
/// everything arrives byte for byte. It cannot defend against the *first*
/// parser — `cmd.exe` still expands `%NAME%` and still stops at a newline —
/// which is why the WSL path wraps its output in [encodedPosixShellCommand].
String quotePosixShellArgument(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";

/// The POSIX shell command that runs [parts], quoted for that shell. `exec` so
/// the shell is replaced rather than waiting on it: the pane's process tree
/// stays the depth it was, and a signal to it still reaches the agent.
String posixShellCommand(List<String> parts) =>
    'exec ${parts.map(quotePosixShellArgument).join(' ')}';

/// [parts] as two argv tokens that carry it into a POSIX shell across a Windows
/// command line without either parser touching it.
///
/// The tokens are `eval` and `$(echo '<base64>'|base64 -d)`. The second **has
/// to arrive double-quoted**, and does: it contains spaces, so every Windows
/// renderer wraps it in `"…"`, which is the shell's *weak* quote — unquoted it
/// would be split on IFS. It asks only `base64 -d` of the distribution, and
/// costs a quarter of the usable prompt length against `cmd`'s 8191-char
/// limit.
List<String> encodedPosixShellCommand(List<String> parts) {
  final blob = base64Encode(utf8.encode(posixShellCommand(parts)));
  return ['eval', '\$(echo \'$blob\'|base64 -d)'];
}

/// Quotes one argument for a command line `cmd.exe` will re-parse, by
/// `CommandLineToArgvW`'s rules.
///
/// It deliberately does not escape `%` (there is no reliable escape for it on a
/// `/c` line) and does not quote a value only because it contains
/// `& | < > ^ ( )`, so a single-token `a&b` would start a second command.
/// Neither reaches a user's prompt any more: both agent paths encode instead,
/// and what is left on this line is paths and flags the app supplies itself.
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
