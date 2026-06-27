import '../../../core/process/command_runner.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../environments/domain/local_environment.dart';

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
        // Windows Terminal (wt.exe) and friends are app-execution aliases that
        // only launch through the shell.
        runInShell: true,
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
        return [
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

/// Builds the host command line that resumes [cli]'s session [externalId] using
/// agent executable [agentExecutable], wrapping in `wsl.exe` when the session
/// lives in a WSL [environment].
List<String> resumeCommandLine({
  required String agentExecutable,
  required String cli,
  required String externalId,
  required ExecutionEnvironment environment,
  required EnvironmentPath cwd,
}) {
  final resumeArgs = switch (cli) {
    'claudeCode' => ['--resume', externalId],
    'codex' => ['resume', externalId],
    _ => <String>[],
  };
  final base = [agentExecutable, ...resumeArgs];
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
