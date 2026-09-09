import 'dart:convert';

import '../domain/agent_pane_launch.dart';
import '../domain/launch_context.dart';
import '../domain/shell_integration.dart';
import '../domain/wsl_shell_integration.dart';
import '../domain/terminal_profile.dart';

/// A concrete process launch for a host ConPTY: which executable, its arguments,
/// and the host working directory (when the shell itself sets the cwd).
///
/// Pure and testable — separated from the actual [Pty] spawn so the
/// shell-selection logic can be unit-tested without a process.
///
/// A [PtyLaunch] is **already wrapped for its context**. It is deliberately not
/// a [ShellCommand] and cannot be turned back into one, which is what makes
/// double-wrapping impossible rather than merely discouraged.
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

  /// Names the launch **without any environment value**.
  ///
  /// [environment] carries the user's secrets. The inherited default —
  /// `Instance of 'PtyLaunch'` — was already safe, and this is not an
  /// improvement on it for readability so much as a way to stop the safe
  /// version being replaced later by a helpful one that interpolates the map.
  /// A test asserts no value appears here.
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
/// Windows-host shells receive [workingDirectory] directly. A WSL profile is
/// launched via `cmd.exe /c wsl.exe -d <distro>` ([throughCommandPrompt] says
/// why the wrapper is there); the working directory is handed to WSL with
/// `--cd` (it accepts a Windows path and translates it) rather than set on the
/// host process. A POSIX [context] — the app itself running on Linux/macOS,
/// where none of those executables exist — opens the login shell instead.
///
/// [context] defaults to the Windows-host reading of [profile], which is what
/// every caller meant before the context was explicit.
///
/// [shellIntegration] adds OSC 133 command markers for the shells that support
/// it. It defaults to `false` and, when false, every launch is byte-identical to
/// what shipped before shell integration existed — a shell that cannot be
/// integrated must behave exactly as it always did.
/// [environment] is the user's own variables, resolved once at launch by
/// `terminalInstanceFactoryProvider`. It is empty for every caller that does
/// not pass it, which keeps every existing launch byte-identical.
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
      // Still spawned directly, and still *nested* because of it: PowerShell's
      // first positional parameter is `-Command`, so the duplicate token
      // [throughCommandPrompt] describes binds to it and the whole rest of the
      // line becomes a command string — measured as two `powershell.exe`
      // processes, with `-NoLogo`/`-NoExit` applying only to the inner one. It
      // works (the inner shell is the one the user types into, and it loads the
      // profile before the bootstrap, which is what shell integration needs),
      // so it is left exactly as it shipped: the fix is to route it through
      // [throughCommandPrompt] as the WSL branch now does, but this is the
      // default profile and no unit test can see a real pane.
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
      // `cmd` discards the stray token — measured as one shell, one banner, one
      // prompt, identical to a bare `cmd.exe`.
      return PtyLaunch(
        executable: 'cmd.exe',
        workingDirectory: workingDirectory,
        environment: environment,
      );
    case ShellContextKind.wsl:
      // Through `cmd.exe /c` for the reason [throughCommandPrompt] documents:
      // spawned directly, the duplicated leading token made the ConPTY command
      // line `wsl.exe wsl.exe -d <distro> --cd <dir>`, and `wsl.exe` reads that
      // second token as *the command to run inside the distro* — so the pane
      // reached its shell by having the distro's login shell exec a PE back out
      // through interop.
      //
      // Measured on the owner's machine (Windows 10.0.26200, archlinux):
      // `wsl.exe -d archlinux nonexistentcmd123` answers `zsh:1: command not
      // found`, which is the login shell; one live agent pane showed three
      // `wsl.exe` processes where one would do; and an *unquoted* Windows
      // `--cd` path fails outright with `Wsl/E_INVALIDARG`, because zsh eats
      // the backslashes before the re-exec'd `wsl.exe` ever sees them. With
      // interop off the login shell cannot exec the PE at all, reads it as a
      // script, and the pane dies as the owner screenshotted:
      //
      //   /mnt/c/Users/.../WindowsApps/wsl.exe: line 1: MZ: command not found
      //   [process exited with code 127]
      //
      // `cmd.exe /c wsl.exe -d <distro> --cd <dir>` reaches the distro's login
      // shell directly, with no Linux round-trip and nothing for interop to be
      // needed for.
      final distro = target.wslDistribution ?? '';
      // Integrated, the pane's first command is the bootstrap, carried by the
      // same `cmd.exe /c wsl.exe … -- eval $(…|base64 -d)` payload every agent
      // launch already crosses on. The shape of the line does not change; only
      // what it carries, and the bootstrap execs the login shell either way.
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
      // so `cmd.exe` is left wherever the app is rather than pointed at a Linux
      // path Windows cannot resolve.
      return throughCommandPrompt([
        'wsl.exe',
        '-d',
        distro,
        if (workingDirectory != null) ...['--cd', workingDirectory],
      ], environment: withWslEnv(environment));
  }
}

/// [environment] plus the `WSLENV` that makes it cross into a distribution.
///
/// A Win32 variable reaches a WSL child **only** if `WSLENV` names it, so this
/// is the one place the list is built and the three WSL launch paths all go
/// through it rather than each spelling it out.
///
/// `/u` on every name — Win32 → WSL, no path translation. Never `/p`: a value
/// that happens to look like a path (an API base URL, a token with slashes)
/// would be rewritten on the way in, silently.
///
/// **The names are visible; the values are not.** `WSLENV` is an ordinary
/// variable, so inside the distribution `echo $WSLENV` prints the name of every
/// variable carried in. That is inherent to the mechanism, and the settings
/// page says so rather than leaving it to be discovered.
///
/// Returns [environment] unchanged when it is empty, so a launch that carries
/// nothing is byte-identical to what it was before this existed.
Map<String, String> withWslEnv(Map<String, String> environment) {
  if (environment.isEmpty) return environment;
  return {
    ...environment,
    'WSLENV': environment.keys.map((k) => '$k/u').join(':'),
  };
}

/// One Windows command line, handed to `cmd.exe /c` so that `cmd` re-parses it.
///
/// **Every** ConPTY child is spawned as `<exe> <exe> <args…>`: `flutter_pty`
/// 0.4.2's `build_command` writes the executable and then every entry of
/// `argv`, and `flutter_pty.dart` has already put the executable at `argv[0]`.
/// `cmd.exe` is the only wrapper that survives that — measured on Windows
/// 10.0.26200, `cmd.exe cmd.exe` starts exactly one shell and
/// `cmd.exe cmd.exe /c <line>` runs `<line>` — because it discards the stray
/// leading token and re-parses the rest. That re-parse is also what restores
/// the quoting `build_command` throws away by concatenating with single spaces.
///
/// The price is `cmd.exe`'s own expansion: a `%NAME%` in [parts] arrives
/// substituted, as [quoteWindowsCommandArgument] already documents for the
/// agent path.
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
/// [context] defaults to the Windows-host reading of [launch] — a WSL launch
/// crosses into its distribution, anything else is Windows-native — which is
/// what every caller meant before the context was explicit. Pass
/// `LaunchContext.forAgent(launch, hostIsWindows: Platform.isWindows)` to get
/// the real one.
///
/// The session id is stamped into the child's environment rather than passed as
/// an argument, because it has to reach a *grandchild* — the MCP bridge the
/// agent spawns — and an argument would not. For WSL that also means naming the
/// variable in `WSLENV`, which is the only way a Win32 variable crosses into the
/// distro; [wrapForPty] does that.
///
/// A derived port base rides along beside it for the same reason and by the same
/// route: the thing that has to read it is a script the agent runs, which is a
/// grandchild too. See [kSessionPortBaseEnvironmentVariable].
///
/// [environment] is the user's own variables. They are layered **under** the
/// session plumbing on purpose: `KARMASHALA_SESSION_ID` and the port base are
/// how the pane reaches its own MCP bridge, so a user variable must never be
/// able to displace one. (`envNameRefusal` also refuses the `KARMASHALA_`
/// prefix outright, so this ordering is the second of two guards rather than
/// the only one.)
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
            // Beside the id and through the same `WSLENV` plumbing — the
            // wrapper names every key it is given, so a second variable costs
            // nothing to carry. See [kSessionPortBaseEnvironmentVariable]: it
            // is a namespace a repository's own scripts opt into, not a lock,
            // and it exists so two worktree sessions running the same script do
            // not both bind the same port.
            kSessionPortBaseEnvironmentVariable: '${sessionPortBase(
              launch.sessionId!,
            )}',
          },
        },
      ),
      context ?? LaunchContext.forAgent(launch, hostIsWindows: true),
    );

/// The **one** place a command gets a wrapper put in front of it for a ConPTY.
///
/// It consumes a [ShellCommand] — a command in the words of its own
/// environment — and returns a [PtyLaunch], which is not a [ShellCommand] and
/// has no route back to being one. So "wrap the wrapped launch again" is not a
/// mistake that compiles, and every caller below can be read as asking one
/// question: which context is this going into?
PtyLaunch wrapForPty(ShellCommand command, LaunchContext context) {
  switch (context.kind) {
    case ShellContextKind.posix:
      // Already inside the target shell (the app on Linux/macOS, or running in
      // the very distribution the command names). There is nothing to cross, so
      // the command is spawned exactly as written — in particular a launch for
      // a WSL environment must NOT pick up `wsl.exe` here.
      return PtyLaunch(
        executable: command.executable,
        arguments: command.arguments,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
      );
    case ShellContextKind.windowsNative:
    case ShellContextKind.powerShell:
      // **PowerShell is the Windows-native shell for an agent**, not `cmd.exe`.
      // A Windows session's pane, its "copy command" line and the external
      // terminal it opens into now all speak the same shell, which is what the
      // owner asked for and what stops a copied line being valid in one place
      // and rejected in another.
      //
      // The problem this has to solve either way: `flutter_pty` 0.4.2 builds its
      // Windows command line as `<exe> <argv…>` while the Dart side has already
      // put the executable at `argv[0]`, so the child is handed **its own
      // executable name as its first argument** and the rest are concatenated
      // with single spaces and no quoting. Directly-spawned, that starts a
      // `codex.exe` turn asking about "codex.exe" and splits any argument
      // containing a space.
      //
      // `-EncodedCommand` answers both: the whole script is one base64 token, so
      // there is nothing for the unquoted concatenation to split, and the
      // duplicated leading token binds to PowerShell's positional `-Command` and
      // merely nests a second shell (measured; it is what the PowerShell profile
      // has always done). It also removes `cmd`'s `%NAME%` expansion from the
      // problem entirely — a prompt containing `%PATH%` used to arrive
      // substituted on this path, which is the one thing
      // [quoteWindowsCommandArgument] promises not to do to it.
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
      // Only when the profile *names* `cmd.exe`. `cmd` ignores the duplicated
      // leading token and re-parses the rest, so one `/c` argument carrying a
      // correctly quoted command line survives `flutter_pty` the same way.
      return throughCommandPrompt(
        command.parts,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
      );
    case ShellContextKind.wsl:
      // **Through `cmd.exe /c`, carrying a base64 payload the distro's login
      // shell decodes.** Two separate facts force that shape, both measured on
      // Windows 10.0.26200 against `archlinux`.
      //
      // 1. `cmd.exe` has to be the wrapper. Spawned directly, `flutter_pty`'s
      //    duplicated leading token makes the real command line
      //    `wsl.exe wsl.exe -d <distro> …`, and `wsl.exe` reads that second
      //    token as *the command to run inside the distro*: the login shell
      //    then execs a Windows PE back out through `binfmt_misc`. It works
      //    every day and dies the moment WSL interop is unregistered, as
      //
      //      /mnt/c/…/WindowsApps/wsl.exe: line 1: MZ: command not found
      //
      //    — the shell reading the PE's `MZ` header as a script.
      //
      // 2. **`wsl.exe … -- <command>` is not an argv hand-off.** WSL takes the
      //    command line *tail* after `--` and runs it through the
      //    distribution's login shell: `wsl.exe -d archlinux -- echo '$0 // $$'`
      //    answers `/usr/sbin/zsh // 1283809`, and every Windows quoting
      //    character survives into that shell and is parsed again under POSIX
      //    rules. So this is a **two-parser line**, and the arguments have to be
      //    correct for the second parser as well as the first. They were not:
      //
      //      * a prompt with a newline truncated at `cmd`'s end-of-line and left
      //        the opening quote dangling — `zsh:1: unmatched "`, the pane the
      //        owner reported, and the failure mode of *every* multi-line
      //        prompt;
      //      * `` `id -u` `` and `$(id -u)` in a prompt were **executed** —
      //        measured: the prompt arrived as `run 1000 now`, and
      //        `$(touch /tmp/x)` really created the file. A prompt is written by
      //        agents and pasted by users, so that is a command-injection hole,
      //        not only a robustness bug;
      //      * `$HOME` was expanded and `\\server` was eaten down to `\server`.
      //
      // The fix is the one the Windows-native branch above already reached for
      // the same class of reason: stop quoting for two parsers at once and
      // encode instead. [encodedPosixShellCommand] is the POSIX
      // `-EncodedCommand`. Its base64 alphabet has no character `cmd` rewrites,
      // no newline for `cmd` to truncate at and nothing for a shell to expand,
      // so the payload crosses both parsers untouched and is quoted exactly
      // once — by us, for the shell that will actually read it.
      //
      // That also retires the `%`-in-the-command escape hatch this branch used
      // to have (a prompt containing a percent sign was sent the interop
      // round-trip so `cmd` could not substitute `%NAME%` into it): a prompt's
      // percent signs are inside the base64 now. `--cd` is still spelled out on
      // the `cmd` line because `wsl.exe` is what translates a Windows path, so
      // a *working directory* containing `%NAME%` would still be substituted —
      // the same exposure the shell-profile branch above has always had, and
      // the app supplies that path rather than the user's prose.
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
        // wsl.exe sets the child's directory itself, so the host process must
        // not also be pointed at a Linux path it cannot resolve.
        // A Win32 variable only crosses into the distro if `WSLENV` names it.
        environment: withWslEnv(command.environment),
      );
  }
}

/// The same context decision, for a command handed to an **external** terminal
/// (Windows Terminal, WezTerm, a pasted `wsl.exe …` line) rather than a ConPTY.
///
/// Only the environment crossing belongs here: which shell the external
/// terminal itself is (PowerShell, cmd, …) is that terminal's own argument
/// convention, applied by `SystemTerminalService`. Nothing is quoted for *that*
/// shell, because unlike `flutter_pty` those paths deliver argv properly and
/// quoting twice would corrupt it.
///
/// **The WSL crossing is not one of those paths, and used to be treated as
/// one.** `wsl.exe … -- <command>` hands the command line *tail* to the
/// distribution's login shell rather than handing it an argv, so however
/// faithfully the terminal renders these strings, a shell parses them again on
/// the far side — the same double-parse [wrapForPty] documents, reached by a
/// different route and carrying the same prompt. So the command crosses
/// [encodedPosixShellCommand] here too. Every consumer of this list renders it
/// with Windows quoting (`_argsFor`'s PowerShell and `cmd` forms, and
/// `Process.start`'s own escaping), which is exactly the double quote that
/// token needs.
///
/// Takes a [ShellCommand] and returns a plain argv, so — as with [wrapForPty] —
/// its own output cannot be fed back in.
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
/// The counterpart to [quoteWindowsCommandArgument], and it exists for the same
/// reason: a WSL launch is a command line **two** parsers read, and the second
/// of them is the distribution's login shell. `wsl.exe … -- <command>` does not
/// hand that shell an argv; it hands it the command line tail, which the shell
/// then parses under its own rules. Quoting only for Windows left every POSIX
/// metacharacter live on the other side.
///
/// Single quotes, because they are the one POSIX construct with **no**
/// exceptions inside them: no expansion, no command substitution, no backslash
/// escapes. Everything the caller passes arrives byte for byte. An embedded
/// single quote is the only thing that cannot appear, so it is spelled the
/// standard way — close, escape it outside the quotes, reopen (`'\''`).
///
/// It promises not to mangle a user's prompt, and unlike
/// [quoteWindowsCommandArgument] it has no `%` caveat to declare: a percent
/// sign means nothing to a POSIX shell. What it cannot defend against on its
/// own is the *first* parser — `cmd.exe` still expands `%NAME%` and still stops
/// at a newline — which is why the WSL path wraps its output in
/// [encodedPosixShellCommand] rather than putting it on the line directly.
String quotePosixShellArgument(String value) =>
    "'${value.replaceAll("'", r"'\''")}'";

/// The POSIX shell command that runs [parts], quoted for that shell.
///
/// `exec` so the shell is *replaced* by the command rather than waiting on it:
/// the pane's process tree stays the depth it was before the payload was
/// encoded, and a signal delivered to it still reaches the agent.
String posixShellCommand(List<String> parts) =>
    'exec ${parts.map(quotePosixShellArgument).join(' ')}';

/// [parts] as two argv tokens that carry it into a POSIX shell across a Windows
/// command line without either parser touching it.
///
/// The POSIX answer to `powershell.exe -EncodedCommand`, reached for the same
/// reason the native branch reached for that one: a `wsl.exe … -- <command>`
/// line is read by `cmd.exe` and then again by the distribution's login shell,
/// and one string cannot be quoted correctly for two parsers at once. So the
/// command is not quoted for them at all — it is encoded into an alphabet
/// neither of them has an opinion about, and quoted exactly once, by
/// [quotePosixShellArgument], for the shell that actually runs it.
///
/// The tokens are `eval` and `$(echo '<base64>'|base64 -d)`, and each part of
/// that is load-bearing:
///
/// * the base64 alphabet is `A-Za-z0-9+/=`. Nothing `cmd` expands (no `%`),
///   nothing it stops at (no newline), nothing it reads as syntax (no
///   `& | < > ^ ( )`), and nothing a shell globs or splits;
/// * **the second token has to arrive double-quoted, and it does.** It contains
///   spaces, so every Windows command-line renderer wraps it in `"…"` —
///   [quoteWindowsCommandArgument] here, PowerShell's and Dart's native-command
///   escaping on the external-terminal paths. A `"` is Windows' only quote and
///   the shell's *weak* one, so what the login shell reads back is one word
///   with the substitution live. Unquoted it would be split on IFS and a
///   newline in the prompt would become a space;
/// * `$(…)` is parsed from scratch by the shell, so the `'…'` inside it really
///   quotes the blob instead of being literal apostrophes;
/// * `base64 -d` is coreutils, and busybox spells it the same way. That is the
///   single thing this asks of the distribution.
///
/// The cost, stated plainly: base64 is 4 bytes for 3, and a `cmd.exe` command
/// line stops at 8191 characters, so the longest prompt that can be launched
/// this way is about a quarter shorter than before. A prompt that does not fit
/// fails loudly, where the alternative was one that arrived silently altered —
/// or executed.
List<String> encodedPosixShellCommand(List<String> parts) {
  final blob = base64Encode(utf8.encode(posixShellCommand(parts)));
  return ['eval', '\$(echo \'$blob\'|base64 -d)'];
}

/// Quotes one argument for a command line `cmd.exe` will re-parse.
///
/// Follows `CommandLineToArgvW`'s rules — wrap in double quotes when the value
/// contains whitespace or a quote, escape embedded quotes, and double the
/// backslashes that immediately precede one — because that is what the agent's
/// own argument parser will apply on the other side.
///
/// **Two things it deliberately does not do**, both of which are about
/// `cmd.exe` rather than about `CommandLineToArgvW`:
///
/// * it does not escape `%`. `cmd` expands `%NAME%` for variables that exist,
///   and there is no reliable escape for it on a `/c` command line (`%%` is a
///   batch-file convention and is not collapsed here). Unknown names are left
///   alone;
/// * it does not quote a value **only** because it contains `& | < > ^ ( )`.
///   Those are `cmd` syntax outside quotes, and a value with no space, tab or
///   quote is returned untouched — so a single-token `a&b` handed to
///   [throughCommandPrompt] would start a second command.
///
/// Neither reaches a user's prompt any more. The WSL agent path encodes its
/// command ([encodedPosixShellCommand]) and puts nothing on the `cmd` line but
/// `--cd`; the Windows-native path is PowerShell `-EncodedCommand`; and
/// [wrapForPty]'s `commandPrompt` branch is unreachable for an agent, because
/// `LaunchContext.forAgent` only ever answers `windowsNative`, `wsl` or `posix`.
/// What is left on this line is paths and flags the app supplies itself.
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
