import 'dart:convert';

import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_core/shell_integration.dart';

/// A concrete process launch for a host ConPTY. Deliberately not a
/// [ShellCommand] and with no route back, so double-wrapping cannot compile.
class PtyLaunch {
  const PtyLaunch({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.exactArgv = false,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Extra variables layered over the host environment for this child only —
  /// an agent pane uses it to tell the agent which session it is running in.
  final Map<String, String> environment;

  /// Whether [arguments] are an **exact argv** the child must receive as
  /// written. A spawner that builds one Windows command line owes them
  /// `CommandLineToArgvW` quoting and must not repeat the executable — which
  /// the session host always did, and `flutter_pty` did not (see
  /// [flutterPtyStartFor]). `false` is every launch shaped *for* `flutter_pty`'s
  /// unquoted concatenation — the `cmd.exe /c <line>` family — left as shipped.
  final bool exactArgv;

  @override
  bool operator ==(Object other) =>
      other is PtyLaunch &&
      other.executable == executable &&
      other.exactArgv == exactArgv &&
      other.workingDirectory == workingDirectory &&
      _mapEquals(other.environment, environment) &&
      _listEquals(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(
    executable,
    workingDirectory,
    exactArgv,
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
/// into — a WSL profile takes its directory from `--cd`, not the host process.
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
      // Without integration: still spawned directly and still *nested*,
      // because the duplicate token binds to PowerShell's positional
      // `-Command`. Left as it shipped — it carries no script.
      //
      // With integration the bootstrap rides as a plain, readable `-Command`
      // on an exact argv: one PowerShell, never an encoded one. An
      // `-EncodedCommand` from an unsigned parent is among the strongest
      // signals behavioural antivirus scores (docs/windows-antivirus.md).
      // `-NoExit` keeps the session interactive after the bootstrap, and
      // `-Command` runs after the profiles exactly as the encoded form did.
      // Not `-File`: the owner's execution policy is `Restricted`, which
      // refuses a script file and does not apply to `-Command`.
      return PtyLaunch(
        executable: 'powershell.exe',
        arguments: [
          '-NoLogo',
          if (integrate) ...[
            '-NoExit',
            '-Command',
            powerShellIntegrationScript(),
          ],
        ],
        workingDirectory: workingDirectory,
        environment: environment,
        exactArgv: integrate,
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
      // Through `cmd.exe /c`: spawned directly, `wsl.exe` reads the duplicated
      // token as the command to run, and the pane dies when interop is off.
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

/// [environment] plus the `WSLENV` a Win32 variable must be named in to cross
/// into a distribution. `/u`, never `/p`, which rewrites path-like values.
Map<String, String> withWslEnv(Map<String, String> environment) {
  if (environment.isEmpty) return environment;
  return {
    ...environment,
    'WSLENV': environment.keys.map((k) => '$k/u').join(':'),
  };
}

/// One Windows command line handed to `cmd.exe /c`, the only wrapper that
/// survives `flutter_pty` spawning every child as `<exe> <exe> <args…>`.
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

/// Builds the ConPTY launch that runs an agent CLI in a pane. The session id
/// rides in the *environment*, because it has to reach a grandchild — the MCP
/// bridge the agent spawns.
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
      // The launch's own volatile environment — the self-update switch — over
      // the host overlay, and under the session id, which nothing else sets.
      ...launch.environment,
      if (launch.sessionId != null) ...{
        kSessionIdEnvironmentVariable: launch.sessionId!,
        // Beside the id and through the same `WSLENV` plumbing. A
        // namespace a repository's scripts opt into, so two worktree
        // sessions running one script do not both bind the same port.
        kSessionPortBaseEnvironmentVariable:
            '${sessionPortBase(launch.sessionId!)}',
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
      // PowerShell, not `cmd.exe`, so the pane and the copied line speak one
      // shell and `%NAME%` is never expanded. A plain `-Command` on an exact
      // argv — it was `-EncodedCommand`, which behavioural antivirus treats as
      // a dropper signal (docs/windows-antivirus.md) — in printable ASCII only,
      // because `flutter_pty` casts each byte of its command line to a `WCHAR`.
      return PtyLaunch(
        executable: 'powershell.exe',
        arguments: [
          '-NoLogo',
          '-NoProfile',
          '-Command',
          powerShellInvocation(command.parts),
        ],
        workingDirectory: command.workingDirectory,
        environment: command.environment,
        exactArgv: true,
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
      // `wsl.exe … -- <command>` hands its tail to the login shell, which
      // parses a Windows-quoted line a second time under POSIX rules.
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

/// The same context decision for an **external** terminal, not a ConPTY. Only
/// the WSL crossing needs wrapping, because it hands its tail to a login shell.
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

/// The PowerShell statement that runs [parts] — `& <exe> <arg>…` — with every
/// part a [powerShellLiteral], so the whole script is printable ASCII.
String powerShellInvocation(List<String> parts) =>
    '& ${parts.map(powerShellLiteral).join(' ')}';

/// A PowerShell expression that evaluates to exactly [value], written in
/// **printable ASCII only**.
///
/// Printable ASCII goes in a single-quoted literal, where PowerShell expands
/// nothing (`$`, backtick, `%`, `&` and `"` are inert) and only `'` is doubled.
/// Anything else — control characters and every code unit past `~` — is its
/// UTF-16 code units in `[string]::new([char[]](…))`, joined to the literals
/// with `+` inside parentheses, which is how one expression is one argument.
/// Two reasons it cannot go in raw: `flutter_pty` writes its command line a
/// byte at a time into `WCHAR`s, so UTF-8 arrives as garbage; and PowerShell
/// also ends a single-quoted string at a *typographic* quote (U+2018–U+201B),
/// so "don’t" in a prompt cut the script short even where the bytes survived.
String powerShellLiteral(String value) {
  if (value.isEmpty) return "''";
  final segments = <String>[];
  final plain = StringBuffer();
  final codes = <int>[];
  void flushPlain() {
    if (plain.isEmpty) return;
    segments.add("'${plain.toString().replaceAll("'", "''")}'");
    plain.clear();
  }

  void flushCodes() {
    if (codes.isEmpty) return;
    segments.add('[string]::new([char[]](${codes.join(',')}))');
    codes.clear();
  }

  for (final unit in value.codeUnits) {
    if (unit >= 0x20 && unit <= 0x7E) {
      flushCodes();
      plain.writeCharCode(unit);
    } else {
      flushPlain();
      codes.add(unit);
    }
  }
  flushPlain();
  flushCodes();
  return segments.length == 1 ? segments.single : '(${segments.join('+')})';
}

/// What `Pty.start` is handed for [launch]: its arguments, and whether the
/// vendored `flutter_pty` may repeat the executable as `argv[0]`.
///
/// On Windows `flutter_pty` joins its arguments with single spaces and quotes
/// nothing, so a [PtyLaunch.exactArgv] launch is quoted here — by the same
/// `CommandLineToArgvW` rules the session host applies — into **one**
/// pre-quoted tail, and the repeated executable is suppressed so PowerShell is
/// not started twice. Every other launch is handed over exactly as before.
({List<String> arguments, bool repeatExecutable}) flutterPtyStartFor(
  PtyLaunch launch, {
  required bool hostIsWindows,
}) {
  if (!hostIsWindows || !launch.exactArgv) {
    return (arguments: launch.arguments, repeatExecutable: true);
  }
  return (
    arguments: [
      if (launch.arguments.isNotEmpty)
        launch.arguments.map(quoteWindowsCommandArgument).join(' '),
    ],
    repeatExecutable: false,
  );
}

/// Quotes one argument for a **POSIX** shell. Single quotes, so everything
/// arrives byte for byte; it cannot defend against `cmd.exe`, the first parser.
String quotePosixShellArgument(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";

/// The POSIX shell command that runs [parts], quoted for that shell. `exec` so
/// the shell is replaced rather than waiting on it: the pane's process tree
/// stays the depth it was, and a signal to it still reaches the agent.
String posixShellCommand(List<String> parts) =>
    'exec ${parts.map(quotePosixShellArgument).join(' ')}';

/// [parts] as two argv tokens that cross a Windows command line untouched: the
/// second contains spaces, so it arrives double-quoted and survives IFS.
List<String> encodedPosixShellCommand(List<String> parts) {
  final blob = base64Encode(utf8.encode(posixShellCommand(parts)));
  return ['eval', '\$(echo \'$blob\'|base64 -d)'];
}

/// Quotes one argument for a command line `cmd.exe` re-parses. It escapes
/// neither `%` nor `& | < > ^ ( )`, so only app-supplied text may reach it.
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
