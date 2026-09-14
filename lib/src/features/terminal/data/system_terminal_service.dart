import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:agent_cli/process.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../../../core/apps/installed_application.dart';
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
  /// `PATH` — Terminal.app and iTerm2 put nothing on `PATH` at all.
  final List<String> appBundlePaths;

  String get id => kind.name;

  @override
  bool operator ==(Object other) =>
      other is SystemTerminal && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

/// Detects which external terminals are installed and launches a command in one.
/// Everything runs through the Windows-host [CommandRunner] (constraint 6) as a
/// fire-and-forget `start` that returns as soon as the window opens.
class SystemTerminalService {
  SystemTerminalService(this._runner, {bool? windows, bool? macOs})
    : _windows = windows ?? Platform.isWindows,
      _macOs = macOs ?? Platform.isMacOS;

  final CommandRunner _runner;

  /// Injected so the host can be chosen in a test. Everything about which
  /// terminals exist and how they are launched turns on these two.
  final bool _windows;
  final bool _macOs;

  /// The terminals worth looking for on this host — offering `wt.exe` on a Mac
  /// gave macOS a settings page whose every option was missing.
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

  /// Whether [executable] resolves on `PATH`. `where.exe` on Windows; elsewhere
  /// `command -v` through a shell, since it is a builtin and is the portable
  /// spelling (`which` is not guaranteed to exist).
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
    // A `.app` the user picked is a bundle like the two known ones: handed a
    // script to run, never a command line it would read as a file to open.
    if (terminal.kind == SystemTerminalKind.macTerminal ||
        terminal.kind == SystemTerminalKind.iterm2 ||
        isMacApplicationBundle(terminal.executable)) {
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
        // Only Windows Terminal (wt.exe) is an app-execution alias that needs
        // the shell; wrapping a real exe in `cmd /c` mangles its nested args.
        runInShell: terminal.kind == SystemTerminalKind.windowsTerminal,
      ),
    );
  }

  /// Opens Terminal.app or iTerm by handing it a script: neither takes a command
  /// on its command line — `open -a Terminal foo` opens a *file* called foo.
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
        // none exists), so a session opens as a tab rather than a window.
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

/// The agent CLI flags for [selection], from the registry. An agent it does not
/// know gets **none**: another CLI's flag may mean something else (principle 5).
List<String> permissionArgsFor(
  String cli,
  PermissionSelection? selection, {
  AgentRegistry registry = AgentRegistry.builtIn,
}) {
  final support = registry.byId(cli)?.launch.permission;
  if (support == null || !support.isKnown) return const <String>[];
  return support.argumentsFor(selection);
}

/// The TTY arguments continuing [cli]'s [externalId], from
/// [AgentLaunchSpec.interactiveResume]; **nothing** silently starts a new one.
List<String> resumeArgsFor(
  String cli,
  String? externalId, {
  AgentRegistry registry = AgentRegistry.builtIn,
}) => externalId == null || externalId.isEmpty
    ? const <String>[]
    : registry.byId(cli)?.launch.interactiveResume.argumentsFor(externalId) ??
          const <String>[];

/// Why [cli] must not be handed a command line claiming to continue
/// [externalId], or `null` — including when no conversation is named at all.
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

/// A resume run in a directory the conversation was not written in. A caveat,
/// never a refusal: an unmounted drive must not mean the session is gone.
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

/// Whether the two directories are both known and different. No case folding,
/// and paths rather than an agent's own lossy directory key.
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

/// A single shell-pasteable command, spelled for the shell [environment] opens:
/// **Windows PowerShell 5.1 rejects `&&`**, so one syntax for all was broken.
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
  // keeps a `[` in a directory name from being read as a wildcard.
  return 'Set-Location -LiteralPath ${quotePowerShellArgument(cwd)}; '
      '& ${parts.map(quotePowerShellArgument).join(' ')}';
}

/// Quotes one argument for a POSIX shell. A backslash is **not** in the safe
/// set: it escapes the next character in an unquoted `sh` word, so a value
/// carrying one has to be quoted even though it looks inert.
String _shQuote(String value) =>
    RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(value)
    ? value
    : "'${value.replaceAll("'", r"'\''")}'";

/// Builds the host command line that resumes [cli]'s session [externalId],
/// wrapping in `wsl.exe` when the session lives in a WSL [environment].
/// [permission] adds the per-agent permission flags.
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
  // every surface; which shell the terminal itself is belongs to [_argsFor].
  return wrapForExternalTerminal(
    ShellCommand(
      executable: base.first,
      arguments: base.sublist(1),
      workingDirectory: cwd.path,
    ),
    LaunchContext.forEnvironment(environment.wslDistribution),
  );
}
