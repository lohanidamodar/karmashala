import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';
import '../../agents/domain/agent_registry.dart';
import '../../settings/domain/permission_mode.dart';
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

/// The agent CLI flags for a [permissionMode], read from the agent registry so
/// terminal launches honour the same per-agent permission setting as the in-app
/// adapters.
///
/// An agent the registry does not know gets **no** permission flag, letting the
/// agent apply its own default. Guessing one would mean passing a flag invented
/// for a different CLI to a binary we know nothing about — it may not exist
/// there, or may mean something else — which is the wrong side of `PRODUCT.md`
/// principle 5, "dangerous permission-bypass options are never the default".
List<String> permissionArgsFor(String cli, PermissionMode permissionMode) {
  final descriptor = AgentRegistry.builtIn.byId(cli);
  return descriptor?.launch.permissionArgumentsFor(permissionMode) ??
      const <String>[];
}

/// A single shell-pasteable command: `cd <cwd> && <agent> <flags> [resume]`.
///
/// Used by the "copy command" buttons — the user pastes it into whichever shell
/// the session lives in (so it is NOT wsl-wrapped). When [externalId] is null it
/// is a fresh-session command. [permissionMode] adds the per-agent flags.
String shellCommandLine({
  required String agentExecutable,
  required String cli,
  String? externalId,
  required PermissionMode permissionMode,
  required String cwd,
}) {
  final resumeArgs = externalId == null
      ? const <String>[]
      : switch (cli) {
          'claudeCode' => ['--resume', externalId],
          'codex' => ['resume', externalId],
          _ => const <String>[],
        };
  final parts = [
    agentExecutable,
    ...permissionArgsFor(cli, permissionMode),
    ...resumeArgs,
  ];
  return 'cd ${_shQuote(cwd)} && ${parts.map(_shQuote).join(' ')}';
}

String _shQuote(String value) =>
    RegExp(r'^[A-Za-z0-9_@%+=:,./\\-]+$').hasMatch(value)
    ? value
    : "'${value.replaceAll("'", r"'\''")}'";

/// Builds the host command line that resumes [cli]'s session [externalId] using
/// agent executable [agentExecutable], wrapping in `wsl.exe` when the session
/// lives in a WSL [environment]. [permissionMode] adds the per-agent permission
/// flags (e.g. bypass).
List<String> resumeCommandLine({
  required String agentExecutable,
  required String cli,
  required String externalId,
  required ExecutionEnvironment environment,
  required EnvironmentPath cwd,
  PermissionMode permissionMode = PermissionMode.ask,
}) {
  final resumeArgs = switch (cli) {
    'claudeCode' => ['--resume', externalId],
    'codex' => ['resume', externalId],
    _ => <String>[],
  };
  // Permission flags before the resume subcommand/args (global flags first).
  final base = [
    agentExecutable,
    ...permissionArgsFor(cli, permissionMode),
    ...resumeArgs,
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
