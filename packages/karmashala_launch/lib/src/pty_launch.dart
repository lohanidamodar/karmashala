import 'dart:convert';

import 'agent_pane_launch.dart';
import 'launch_context.dart';
import 'shell_integration.dart';
import 'terminal_profile.dart';
import 'wsl_shell_integration.dart';

/// A concrete process launch for the server's PTY. Deliberately not a
/// [ShellCommand] and with no route back, so double-wrapping cannot compile.
class PtyLaunch {
  const PtyLaunch({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.removedEnvironment = const {},
    this.directArgv,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Extra variables layered over the host environment for this child only —
  /// an agent pane uses it to tell the agent which session it is running in.
  final Map<String, String> environment;

  /// Names deleted from the host environment for this child only. Inheriting
  /// is the default everywhere else, so *not* passing something on has to be
  /// said out loud rather than expressed as an absence.
  final Set<String> removedEnvironment;

  /// The argv the server starts instead of [executable] and [arguments]: the
  /// server runs argv[0] **once** and quotes by `CommandLineToArgvW` rules,
  /// so a WSL launch goes straight to `wsl.exe`. Through a `cmd.exe /c`
  /// wrapper the line is quoted a second time and `cmd.exe` does not read
  /// backslash escapes, so the integrated WSL bootstrap never started.
  final List<String>? directArgv;

  /// What the server starts: [directArgv] when there is one,
  /// otherwise the executable and its arguments as they are.
  List<String> get hostArgv => directArgv ?? [executable, ...arguments];

  @override
  bool operator ==(Object other) =>
      other is PtyLaunch &&
      other.executable == executable &&
      _nullableListEquals(other.directArgv, directArgv) &&
      other.workingDirectory == workingDirectory &&
      _mapEquals(other.environment, environment) &&
      _setEquals(other.removedEnvironment, removedEnvironment) &&
      _listEquals(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(
    executable,
    workingDirectory,
    Object.hashAll(arguments),
    directArgv == null ? null : Object.hashAll(directArgv!),
    Object.hashAllUnordered(
      environment.entries.map((e) => '${e.key}=${e.value}'),
    ),
    Object.hashAllUnordered(removedEnvironment),
  );

  /// Names the launch **without any environment value** — [environment] carries
  /// the user's secrets, and a test asserts no value appears here.
  @override
  String toString() =>
      'PtyLaunch($executable, ${arguments.length} argument(s), '
      '${environment.length} environment variable(s)'
      '${removedEnvironment.isEmpty ? '' : ', ${removedEnvironment.length} removed'})';

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static bool _nullableListEquals(List<String>? a, List<String>? b) =>
      a == null || b == null ? a == b : _listEquals(a, b);

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
      // signals behavioural antivirus scores.
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
      return throughCommandPrompt(
        [
          'wsl.exe',
          '-d',
          distro,
          if (workingDirectory != null) ...['--cd', workingDirectory],
        ],
        environment: withWslEnv(environment),
        direct: true,
      );
  }
}

/// The environment a PTY child is handed: [host], minus [removed], minus the
/// POSIX `PATH`/`SHELL`/`WSL*` that leak from a WSL launch and break `wsl.exe`,
/// with [extra] layered last.
///
/// [extra] wins over [removed] by construction — a name Karmashala itself
/// supplies is one the child really is given, whatever the shell exported.
Map<String, String> ptyChildEnvironment({
  required Map<String, String> host,
  Map<String, String> extra = const {},
  Set<String> removed = const {},
  required bool hostIsWindows,
}) {
  final env = Map<String, String>.of(host);
  if (removed.isNotEmpty) {
    // Windows environment names are case-insensitive, so a removal there has to
    // be too, or `anthropic_api_key` survives a strip of `ANTHROPIC_API_KEY`.
    // POSIX names are not, and two spellings really are two variables.
    final wanted = hostIsWindows
        ? {for (final name in removed) name.toLowerCase()}
        : removed;
    env.removeWhere(
      (key, _) => wanted.contains(hostIsWindows ? key.toLowerCase() : key),
    );
  }

  // WSL-interop / Unix-shell leaks; harmless no-ops on a clean launch.
  final shell = env['SHELL'];
  if (shell != null && shell.startsWith('/')) env.remove('SHELL');
  env
    ..remove('WSLENV')
    ..remove('WSL_INTEROP')
    ..remove('WSL_DISTRO_NAME');

  // A POSIX PATH means we were launched from a Unix shell — rebuild a Windows
  // PATH so wsl.exe / powershell.exe / cmd.exe resolve.
  final path = env['Path'] ?? env['PATH'];
  if (path != null && path.startsWith('/')) {
    final sysRoot = env['SystemRoot'] ?? env['windir'] ?? r'C:\Windows';
    env
      ..remove('PATH')
      ..['Path'] =
          '$sysRoot\\System32;$sysRoot;'
          '$sysRoot\\System32\\WindowsPowerShell\\v1.0;'
          '$sysRoot\\System32\\wbem';
  }

  // Layered last so a caller's variables survive the scrubbing above — an agent
  // pane sets WSLENV deliberately, and it must not be the one just removed.
  env.addAll(extra);
  return env;
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
  Set<String> removedEnvironment = const {},
  bool direct = false,
}) => PtyLaunch(
  executable: 'cmd.exe',
  arguments: ['/c', parts.map(quoteWindowsCommandArgument).join(' ')],
  workingDirectory: workingDirectory,
  environment: environment,
  removedEnvironment: removedEnvironment,
  // Only where [parts] name a real executable: `cmd.exe` is also what finds a
  // `.cmd` shim, and that job is not the flutter_pty workaround.
  directArgv: direct ? List.unmodifiable(parts) : null,
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
  // Names, not values: what this launch must *not* inherit from the user's
  // shell. Volatile like [AgentPaneLaunch.environment] beside it.
  removedEnvironment: launch.removedEnvironment,
);

/// The **one** place a command gets a wrapper put in front of it for a ConPTY.
/// It consumes a [ShellCommand] and returns a [PtyLaunch] with no route back,
/// so "wrap the wrapped launch again" is not a mistake that compiles.
PtyLaunch wrapForPty(
  ShellCommand command,
  LaunchContext context, {
  Set<String> removedEnvironment = const {},
}) {
  switch (context.kind) {
    case ShellContextKind.posix:
      // Already inside the target shell, so there is nothing to cross — in
      // particular a WSL-environment launch must NOT pick up `wsl.exe` here.
      return PtyLaunch(
        executable: command.executable,
        arguments: command.arguments,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
        removedEnvironment: removedEnvironment,
      );
    case ShellContextKind.windowsNative:
    case ShellContextKind.powerShell:
      // PowerShell, not `cmd.exe`, so the pane and the copied line speak one
      // shell and `%NAME%` is never expanded. A plain `-Command` on an exact
      // argv — it was `-EncodedCommand`, which behavioural antivirus treats as
      // a dropper signal — in printable ASCII only,
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
        removedEnvironment: removedEnvironment,
      );
    case ShellContextKind.commandPrompt:
      // Only when the profile *names* `cmd.exe`: it ignores the duplicated
      // leading token and re-parses one correctly quoted `/c` line.
      return throughCommandPrompt(
        command.parts,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
        removedEnvironment: removedEnvironment,
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
        // Applied to the `wsl.exe` process, which is all this host owns: a
        // variable the distribution's own profile exports is out of reach.
        removedEnvironment: removedEnvironment,
        direct: true,
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

/// The longest argument [survivesWindowsNativeArgv] lets ride on argv. `cmd.exe`
/// refuses a line past 8,191 characters, and the rest of the agent's command
/// line (its path, the MCP flags, a session id) has to fit beside it.
const kWindowsNativeArgvLimit = 2000;

/// Whether [value] reaches a program's argv **intact** when it is one argument
/// of a Windows-native launch — [wrapForPty]'s `powershell.exe -Command` — and
/// the program is a `.cmd` shim, as npm installs `codex`, `claude` and friends.
///
/// Three parsers stand between the [powerShellLiteral] and the program, and
/// the literal is only correct for the first half of the first:
/// 1. **PowerShell 5.1's native-argument passing** wraps an argument that has
///    whitespace in `"…"` but does not escape a `"` inside it (so the argument
///    splits), and leaves a trailing `\` to escape its own closing quote.
/// 2. **`cmd.exe`**, running the shim, re-reads the line: it expands `%NAME%`,
///    ends the command at a newline (a multi-line brief arrives as its first
///    line), and `& | < > ^` are live wherever its quote state — toggled by
///    every `"` — is off.
/// 3. **The program's own argv parser** (`CommandLineToArgvW` rules, node's
///    included) then reads what `cmd.exe` substituted for `%*`.
///
/// So the rule is an allow-list, not an escape: a non-empty value of at most
/// [kWindowsNativeArgvLimit] characters, with no `"`, `%`, `& | < > ^`, `;`
/// (Windows Terminal's own command separator, for the external-terminal
/// launch), no control character but a tab, and not ending in `\`. Anything
/// else — typographic quotes, Devanagari, emoji — was measured arriving
/// intact. A value that fails is handed over as a file, never as argv.
bool survivesWindowsNativeArgv(String value) {
  if (value.isEmpty || value.length > kWindowsNativeArgvLimit) return false;
  if (value.endsWith(r'\')) return false;
  for (final unit in value.codeUnits) {
    if (unit < 0x20 && unit != 0x09) return false;
    if (unit == 0x7F) return false;
    if (_windowsNativeArgvUnsafe.contains(unit)) return false;
  }
  return true;
}

/// `"` `%` `&` `|` `<` `>` `^` `;` — see [survivesWindowsNativeArgv].
final Set<int> _windowsNativeArgvUnsafe = '"%&|<>^;'.codeUnits.toSet();

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
