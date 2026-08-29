import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';
import '../../agents/domain/agent_registry.dart';
import '../../settings/domain/permission_mode.dart';

/// A standalone terminal emulator installed on the host that we can launch
/// externally (as opposed to the in-app PTY tabs).
enum SystemTerminalKind {
  windowsTerminal,
  wezterm,
  alacritty,
  powerShell,
  cmd,
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
  });

  final SystemTerminalKind kind;
  final String label;
  final String executable;

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
  SystemTerminalService(this._runner);

  final CommandRunner _runner;

  static const _candidates = <SystemTerminal>[
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

  /// The candidate terminals found on `PATH` (via `where.exe`), preserving the
  /// preferred order. PowerShell/cmd are effectively always present.
  Future<List<SystemTerminal>> available() async {
    final found = <SystemTerminal>[];
    for (final term in _candidates) {
      if (await _onPath(term.executable)) found.add(term);
    }
    return found;
  }

  Future<bool> _onPath(String executable) async {
    try {
      final result = await _runner.run(
        CommandRequest(executable: 'where.exe', arguments: [executable]),
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
    final args = _argsFor(terminal.kind, command, workingDirectory);
    // A custom terminal's CLI flags are unknown, so we can't embed the cwd in
    // args — set it as the process working directory instead (best-effort).
    final processCwd =
        terminal.kind == SystemTerminalKind.custom && workingDirectory != null
        ? EnvironmentPath(
            environmentId: localWindowsEnvironmentId,
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
        final invocation = '& ${command.map(_quotePowerShell).join(' ')}';
        final inner = cwd == null
            ? invocation
            : 'Set-Location -LiteralPath ${_quotePowerShell(cwd)}; '
                  '$invocation';
        return ['-NoExit', '-Command', inner];
      case SystemTerminalKind.cmd:
        final invocation = command.map(_quoteCmd).join(' ');
        final inner = cwd == null
            ? invocation
            : 'cd /d ${_quoteCmd(cwd)} && $invocation';
        return ['/K', inner];
      case SystemTerminalKind.custom:
        // Pass the command through; cwd is set as the process working dir.
        return command;
    }
  }

  String _quotePowerShell(String value) => "'${value.replaceAll("'", "''")}'";

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
  if (environment.wslDistribution != null) {
    return [
      'wsl.exe',
      '-d',
      environment.wslDistribution!,
      '--cd',
      cwd.path,
      '--',
      ...base,
    ];
  }
  return base;
}
