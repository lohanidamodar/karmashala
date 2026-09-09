import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import '../domain/launch_context.dart';
import 'pty_launch.dart';

/// A standalone terminal emulator installed on the host that we can launch
/// externally (as opposed to the in-app PTY tabs).
enum SystemTerminalKind {
  windowsTerminal,
  wezterm,
  alacritty,
  powerShell,
  cmd,

  /// macOS: Terminal.app and iTerm2. Both are opened with a script rather than
  /// given a command, because neither takes one on its command line.
  macTerminal,
  iterm2,

  /// Cross-platform emulators with a real CLI, on their POSIX names.
  kitty,
  ghostty,

  /// Linux desktop terminals.
  gnomeTerminal,
  konsole,

  custom,
}

/// Wraps a user-chosen terminal executable as a [SystemTerminal].
SystemTerminal customSystemTerminal(String executablePath) => SystemTerminal(
  kind: SystemTerminalKind.custom,
  label: 'Custom',
  executable: executablePath,
);

class SystemTerminal {
  const SystemTerminal({
    required this.kind,
    required this.label,
    required this.executable,
    this.appBundlePaths = const [],
  });

  final SystemTerminalKind kind;
  final String label;
  final String executable;

  /// Where the app lives on macOS, when it is a bundle rather than something on
  /// `PATH`.
  ///
  /// Terminal.app and iTerm2 put nothing on `PATH`, so looking for them there
  /// finds nothing and the picker comes up empty on the one platform where
  /// Terminal.app is guaranteed to exist.
  final List<String> appBundlePaths;

  String get id => kind.name;

  @override
  bool operator ==(Object other) =>
      other is SystemTerminal && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

/// Detects which external terminals are installed and launches a command in one.
///
/// Everything runs through the Windows-host [CommandRunner] (constraint 6): a
/// fire-and-forget `start` of the terminal executable, which opens its own
/// window and returns immediately.
class SystemTerminalService {
  SystemTerminalService(this._runner, {bool? windows, bool? macOs})
    : _windows = windows ?? Platform.isWindows,
      _macOs = macOs ?? Platform.isMacOS;

  final CommandRunner _runner;

  /// Injected so the host can be chosen in a test. Everything about which
  /// terminals exist and how they are launched turns on these two.
  final bool _windows;
  final bool _macOs;

  /// The terminals worth looking for on this host.
  ///
  /// Host-shaped, because the answer genuinely differs: a Mac has no `wt.exe`
  /// and a Windows box has no Terminal.app, and offering either everywhere gave
  /// macOS a settings page whose every option was missing.
  static List<SystemTerminal> candidatesFor({
    required bool windows,
    required bool macOs,
  }) {
    if (windows) {
      return const [
        SystemTerminal(
          kind: SystemTerminalKind.windowsTerminal,
          label: 'Windows Terminal',
          executable: 'wt.exe',
        ),
        SystemTerminal(
          kind: SystemTerminalKind.wezterm,
          label: 'WezTerm',
          executable: 'wezterm.exe',
        ),
        SystemTerminal(
          kind: SystemTerminalKind.alacritty,
          label: 'Alacritty',
          executable: 'alacritty.exe',
        ),
        SystemTerminal(
          kind: SystemTerminalKind.powerShell,
          label: 'PowerShell',
          executable: 'powershell.exe',
        ),
        SystemTerminal(
          kind: SystemTerminalKind.cmd,
          label: 'Command Prompt',
          executable: 'cmd.exe',
        ),
      ];
    }
    if (macOs) {
      return const [
        SystemTerminal(
          kind: SystemTerminalKind.macTerminal,
          label: 'Terminal',
          executable: 'Terminal',
          appBundlePaths: [
            '/System/Applications/Utilities/Terminal.app',
            '/Applications/Utilities/Terminal.app',
          ],
        ),
        SystemTerminal(
          kind: SystemTerminalKind.iterm2,
          label: 'iTerm',
          executable: 'iTerm',
          appBundlePaths: ['/Applications/iTerm.app'],
        ),
        SystemTerminal(
          kind: SystemTerminalKind.wezterm,
          label: 'WezTerm',
          executable: 'wezterm',
        ),
        SystemTerminal(
          kind: SystemTerminalKind.kitty,
          label: 'kitty',
          executable: 'kitty',
        ),
        SystemTerminal(
          kind: SystemTerminalKind.ghostty,
          label: 'Ghostty',
          executable: 'ghostty',
        ),
        SystemTerminal(
          kind: SystemTerminalKind.alacritty,
          label: 'Alacritty',
          executable: 'alacritty',
        ),
      ];
    }
    return const [
      SystemTerminal(
        kind: SystemTerminalKind.gnomeTerminal,
        label: 'GNOME Terminal',
        executable: 'gnome-terminal',
      ),
      SystemTerminal(
        kind: SystemTerminalKind.konsole,
        label: 'Konsole',
        executable: 'konsole',
      ),
      SystemTerminal(
        kind: SystemTerminalKind.wezterm,
        label: 'WezTerm',
        executable: 'wezterm',
      ),
      SystemTerminal(
        kind: SystemTerminalKind.kitty,
        label: 'kitty',
        executable: 'kitty',
      ),
      SystemTerminal(
        kind: SystemTerminalKind.ghostty,
        label: 'Ghostty',
        executable: 'ghostty',
      ),
      SystemTerminal(
        kind: SystemTerminalKind.alacritty,
        label: 'Alacritty',
        executable: 'alacritty',
      ),
    ];
  }

  /// The candidates actually installed, in the preferred order.
  Future<List<SystemTerminal>> available() async {
    final found = <SystemTerminal>[];
    for (final term in candidatesFor(windows: _windows, macOs: _macOs)) {
      if (term.appBundlePaths.any((path) => Directory(path).existsSync())) {
        found.add(term);
        continue;
      }
      if (await _onPath(term.executable)) found.add(term);
    }
    return found;
  }

  /// Whether [executable] resolves on `PATH`.
  ///
  /// `where.exe` is Windows'. Elsewhere it is `command -v`, run through a
  /// shell because it is a shell builtin — and it is the portable spelling,
  /// where `which` is not guaranteed to exist.
  Future<bool> _onPath(String executable) async {
    try {
      final result = await _runner.run(
        _windows
            ? CommandRequest(executable: 'where.exe', arguments: [executable])
            : CommandRequest(
                executable: '/bin/sh',
                arguments: ['-c', 'command -v ${_quotePosix(executable)}'],
              ),
      );
      return result.ok;
    } catch (_) {
      return false;
    }
  }

  /// Launches [command] (executable + args) in [terminal], starting in
  /// [workingDirectory] when the terminal supports it. Fire-and-forget.
  Future<void> launch(
    SystemTerminal terminal, {
    required List<String> command,
    String? workingDirectory,
  }) async {
    if (terminal.kind == SystemTerminalKind.macTerminal ||
        terminal.kind == SystemTerminalKind.iterm2) {
      await _launchMacApp(terminal, command, workingDirectory);
      return;
    }
    final args = _argsFor(terminal.kind, command, workingDirectory);
    // A custom terminal's CLI flags are unknown, so we can't embed the cwd in
    // args — set it as the process working directory instead (best-effort).
    const cwdOnProcess = {
      SystemTerminalKind.custom,
      SystemTerminalKind.kitty,
      SystemTerminalKind.ghostty,
      SystemTerminalKind.konsole,
    };
    final processCwd =
        cwdOnProcess.contains(terminal.kind) && workingDirectory != null
        ? EnvironmentPath(
            environmentId: localHostEnvironmentId,
            path: workingDirectory,
          )
        : null;
    await _runner.start(
      CommandRequest(
        executable: terminal.executable,
        arguments: args,
        workingDirectory: processCwd,
        // Only Windows Terminal (wt.exe) is an app-execution alias that needs the
        // shell. Wrapping real exes (wezterm/alacritty/custom) in `cmd /c`
        // mangles their nested args, so launch those directly.
        runInShell: terminal.kind == SystemTerminalKind.windowsTerminal,
      ),
    );
  }

  /// Opens Terminal.app or iTerm by handing it a script to run.
  ///
  /// Neither takes a command on its command line — `open -a Terminal foo bar`
  /// opens *files* called foo and bar — so the command is written to an
  /// executable `.command` file and that is what gets opened. This is the same
  /// trick the "Open in Terminal" services use, and it is why these two need a
  /// path of their own rather than another entry in [_argsFor].
  ///
  /// The script deletes itself once it has run, so a directory of dead scripts
  /// does not accumulate, and `exec` means the shell that remains is the
  /// command's own rather than a wrapper around it.
  Future<void> _launchMacApp(
    SystemTerminal terminal,
    List<String> command,
    String? cwd,
  ) async {
    final script = File(
      p.join(
        Directory.systemTemp.path,
        'karmashala-open-${DateTime.now().microsecondsSinceEpoch}.command',
      ),
    );
    final lines = [
      '#!/bin/sh',
      // Removed while it is still running: on POSIX an open file keeps working
      // after its name is gone, so the script finishes and leaves nothing.
      'rm -f ${_quotePosix(script.path)}',
      if (cwd != null) 'cd ${_quotePosix(cwd)} || exit 1',
      'exec ${command.map(_quotePosix).join(' ')}',
      '',
    ];
    await script.writeAsString(lines.join('\n'));
    // 0o755 — `open` will not run a .command that is not executable.
    await Process.run('chmod', ['+x', script.path]);
    await _runner.start(
      CommandRequest(
        executable: 'open',
        arguments: ['-a', terminal.executable, script.path],
      ),
    );
  }

  static String _quotePosix(String value) =>
      "'${value.replaceAll("'", r"'\''")}'";

  List<String> _argsFor(
    SystemTerminalKind kind,
    List<String> command,
    String? cwd,
  ) {
    switch (kind) {
      case SystemTerminalKind.windowsTerminal:
        // `-w 0` targets the current Windows Terminal window (creating one if
        // none exists), so each session opens as a new tab rather than a new
        // window.
        return [
          '-w',
          '0',
          'new-tab',
          if (cwd != null) ...['-d', cwd],
          ...command,
        ];
      case SystemTerminalKind.wezterm:
        return [
          'start',
          if (cwd != null) ...['--cwd', cwd],
          '--',
          ...command,
        ];
      case SystemTerminalKind.alacritty:
        return [
          if (cwd != null) ...['--working-directory', cwd],
          '-e',
          ...command,
        ];
      case SystemTerminalKind.powerShell:
        final invocation =
            '& ${command.map(quotePowerShellArgument).join(' ')}';
        final inner = cwd == null
            ? invocation
            : 'Set-Location -LiteralPath ${quotePowerShellArgument(cwd)}; '
                  '$invocation';
        return ['-NoExit', '-Command', inner];
      case SystemTerminalKind.cmd:
        final invocation = command.map(_quoteCmd).join(' ');
        final inner = cwd == null
            ? invocation
            : 'cd /d ${_quoteCmd(cwd)} && $invocation';
        return ['/K', inner];
      case SystemTerminalKind.kitty:
      case SystemTerminalKind.ghostty:
      case SystemTerminalKind.konsole:
        // All three take the command after `-e`, and none of them takes a
        // working directory the same way, so it is set on the process.
        return ['-e', ...command];
      case SystemTerminalKind.gnomeTerminal:
        return [
          if (cwd != null) '--working-directory=$cwd',
          '--',
          ...command,
        ];
      case SystemTerminalKind.macTerminal:
      case SystemTerminalKind.iterm2:
        // Handled by `_launchMacApp`, which is reached before this.
        return command;
      case SystemTerminalKind.custom:
        // Pass the command through; cwd is set as the process working dir.
        return command;
    }
  }

  String _quoteCmd(String value) => '"${value.replaceAll('"', '""')}"';
}

/// The agent CLI flags for [selection], read from the agent registry so
/// terminal launches honour the same per-agent permission setting as the in-app
/// adapters.
///
/// An agent the registry does not know gets **no** permission flag, letting the
/// agent apply its own default. Guessing one would mean passing a flag invented
/// for a different CLI to a binary we know nothing about — it may not exist
/// there, or may mean something else — which is the wrong side of the design note/// principle 5, "dangerous permission-bypass options are never the default".
List<String> permissionArgsFor(
  String cli,
  PermissionSelection? selection, {
  AgentRegistry registry = AgentRegistry.builtIn,
}) {
  final support = registry.byId(cli)?.launch.permission;
  if (support == null || !support.isKnown) return const <String>[];
  return support.argumentsFor(selection);
}

/// The arguments that continue [cli]'s conversation [externalId] **in a
/// terminal**, read from the agent registry.
///
/// This used to be `switch (cli) { 'claudeCode' => ['--resume', id], 'codex' =>
/// ['resume', id], _ => [] }`, sitting twenty lines below a [permissionArgsFor]
/// that already read the descriptor. The `_ => []` arm is what made it a bug
/// rather than a gap: an agent outside the switch got a command line with no
/// resume arguments at all, which does not fail — it **starts a brand-new
/// conversation wearing the old session's name**, silently, losing whatever the
/// user was continuing. Antigravity, which resumes with `--conversation <id>`
/// and has said so in its descriptor all along, was the agent that hit it.
///
/// [AgentLaunchSpec.interactiveResume] and not `resume`: this is the TTY
/// convention, which differs for Codex (`codex resume <id>` in a terminal vs
/// `codex --resume <id>` in app-server mode).
///
/// An agent the registry has never heard of, or one that declares no resume
/// convention, gets **nothing** — never another agent's flag. Callers must ask
/// [resumeRefusalFor] first, so the user is told in words instead of being
/// handed a command that continues nothing.
List<String> resumeArgsFor(
  String cli,
  String? externalId, {
  AgentRegistry registry = AgentRegistry.builtIn,
}) => externalId == null || externalId.isEmpty
    ? const <String>[]
    : registry.byId(cli)?.launch.interactiveResume.argumentsFor(externalId) ??
          const <String>[];

/// Why [cli] must not be handed a command line claiming to continue
/// [externalId], or `null` when it can be.
///
/// The one place the refusal is worded, because four surfaces need it: the
/// three "copy command" buttons, the two external-terminal opens, and the MCP
/// `open_session` tool. Each of them used to build a command and hand it over
/// regardless.
///
/// Returns `null` when no conversation is named at all: a fresh-session command
/// claims nothing, so there is nothing to be wrong about.
String? resumeRefusalFor(
  AgentRegistry registry,
  String cli,
  String? externalId,
) {
  if (externalId == null || externalId.isEmpty) return null;
  if (registry.byId(cli)?.launch.interactiveResume.isSupported ?? false) {
    return null;
  }
  return '${registry.displayNameFor(cli)} declares no way to continue a '
      'conversation from a command line, so this command would start a new '
      'one rather than continue $externalId. Open the session in Karmashala '
      'instead, where the agent is launched from its own registry entry.';
}

/// The second way a resume can quietly become a fresh conversation: it is run
/// in a directory the conversation was not written in, by an agent nobody has
/// checked can find it from there. `null` when there is nothing to say.
///
/// Deliberately beside [resumeRefusalFor] — same file, same family, one
/// wording — and deliberately **not** part of it, because the two are different
/// strengths of claim and this file family does not blur those:
///
/// * [resumeRefusalFor] is a **certainty**. The registry says this agent has no
///   resume convention at all, so the command line cannot continue anything.
///   There is nothing to weigh; it refuses.
/// * This is a **possibility**. The agent's [AgentResumeLocality] says only that
///   nobody has verified the resume survives a change of directory. Turning that
///   into a refusal would make an unmounted drive or an archived worktree mean
///   "you can never open this session again", and every other unknown in this
///   area resolves the permissive way for exactly that reason —
///   `conversationPresenceProvider` will not refuse on a store it merely failed
///   to read, and `sessionDirectoryPresentProvider` will not call a directory
///   missing when it could not look.
///
/// So the honest answer for an unverified agent is the third of the three the
/// app has: keep the directory stable where it can, refuse where it is certain,
/// and otherwise **say the session may start fresh**. This is that sentence. It
/// is unreachable for the three agents shipped today — all three declare
/// [AgentResumeLocality.anyDirectory] against evidence read off their own stores
/// and binaries — and it is here for the fourth.
///
/// [recordedDirectory] is where the conversation was written and
/// [launchDirectory] is where this run will happen. They differ whenever the app
/// moves a session: an archived worktree falling back to the repository root, a
/// native fork launched into a fresh worktree. Either being null means "we do
/// not know", which says nothing.
String? resumeDirectoryCaveatFor(
  AgentRegistry registry,
  String cli,
  String? externalId, {
  String? recordedDirectory,
  String? launchDirectory,
}) {
  if (externalId == null || externalId.isEmpty) return null;
  final descriptor = registry.byId(cli);
  if (descriptor == null) return null;
  if (descriptor.launch.resumeLocality.findsConversationAnywhere) return null;
  if (!_directoryMoved(recordedDirectory, launchDirectory)) return null;
  return 'This runs in $launchDirectory rather than $recordedDirectory, where '
      'the conversation was written, and ${descriptor.displayName} has not been '
      'verified to find a conversation from anywhere but its own launch '
      'directory. It may open a new conversation rather than continue '
      '$externalId.';
}

/// Whether the two directories are both known and different.
///
/// Compared as written, with trailing separators trimmed and no case folding —
/// the same rule `conversationForDirectory` states for Antigravity's store, and
/// for the same reason: these are paths a CLI was launched in, and folding
/// `/work` onto `/Work` would call two directories one. Comparing paths rather
/// than re-deriving an agent's own directory key is deliberate: Claude's key is
/// a lossy dash-encoding, so two different directories can share one bucket,
/// and a comparison that reproduced the encoding could only ever *miss* a move
/// the path comparison catches.
bool _directoryMoved(String? recorded, String? launch) {
  if (recorded == null || launch == null) return false;
  final a = _withoutTrailingSeparators(recorded);
  final b = _withoutTrailingSeparators(launch);
  return a.isNotEmpty && b.isNotEmpty && a != b;
}

String _withoutTrailingSeparators(String path) {
  var end = path.length;
  while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}

/// A single shell-pasteable command, **spelled for the shell [environment]
/// actually opens**: PowerShell for a Windows-native session, POSIX `sh` for
/// WSL, SSH and a local Mac or Linux host.
///
/// Used by the "copy command" buttons — the user pastes it into whichever shell
/// the session lives in (so it is NOT wsl-wrapped). When [externalId] is null it
/// is a fresh-session command. [permission] adds the per-agent flags.
///
/// [environment] is required rather than defaulted, because one syntax for every
/// environment is exactly the defect it closes: this used to return
/// `cd <cwd> && <parts>` for all of them, and **Windows PowerShell 5.1 rejects
/// `&&` outright** — it is not an operator there until PowerShell 7. A Windows
/// session's copied line was therefore broken on the shell most Windows
/// machines open by default, and looked like a WSL command besides.
String shellCommandLine({
  required String agentExecutable,
  required String cli,
  String? externalId,
  required PermissionSelection? permission,
  required String cwd,
  required EnvironmentKind environment,
  AgentRegistry registry = AgentRegistry.builtIn,
}) {
  final parts = [
    agentExecutable,
    ...permissionArgsFor(cli, permission, registry: registry),
    ...resumeArgsFor(cli, externalId, registry: registry),
  ];
  if (isPosixShell(environment)) {
    return 'cd ${_shQuote(cwd)} && ${parts.map(_shQuote).join(' ')}';
  }
  // `;` separates statements in every PowerShell version where `&&` does not,
  // and `&` is what runs an executable named by a quoted path. `-LiteralPath`
  // keeps a `[` or `]` in a directory name from being read as a wildcard, the
  // same way the PowerShell external-terminal launch above spells it.
  return 'Set-Location -LiteralPath ${quotePowerShellArgument(cwd)}; '
      '& ${parts.map(quotePowerShellArgument).join(' ')}';
}

/// Quotes one argument for a POSIX shell.
///
/// A backslash is **not** in the safe set: it escapes the next character in an
/// unquoted `sh` word, so a value carrying one has to be quoted even though it
/// looks inert.
String _shQuote(String value) =>
    RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value)
    ? value
    : "'${value.replaceAll("'", r"'\''")}'";

/// Builds the host command line that resumes [cli]'s session [externalId] using
/// agent executable [agentExecutable], wrapping in `wsl.exe` when the session
/// lives in a WSL [environment]. [permission] adds the per-agent permission
/// flags (e.g. a bypass).
List<String> resumeCommandLine({
  required String agentExecutable,
  required String cli,
  required String externalId,
  required ExecutionEnvironment environment,
  required EnvironmentPath cwd,
  PermissionSelection? permission,
  AgentRegistry registry = AgentRegistry.builtIn,
}) {
  // Permission flags before the resume subcommand/args (global flags first).
  final base = [
    agentExecutable,
    ...permissionArgsFor(cli, permission, registry: registry),
    ...resumeArgsFor(cli, externalId, registry: registry),
  ];
  // The environment decides the wrapper, in the one place that decides it for
  // every surface. Which shell the external terminal itself is (PowerShell,
  // cmd, ...) is that terminal's own convention and is applied by [_argsFor].
  return wrapForExternalTerminal(
    ShellCommand(
      executable: base.first,
      arguments: base.sublist(1),
      workingDirectory: cwd.path,
    ),
    LaunchContext.forEnvironment(environment.wslDistribution),
  );
}
