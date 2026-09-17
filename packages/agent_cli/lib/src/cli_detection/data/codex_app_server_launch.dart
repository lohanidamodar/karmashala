import '../../environments/execution_environment.dart';

/// The app-server arguments. `--listen stdio://` is the default on both Codex
/// 0.145.0 and 0.153.4, and naming it keeps a future default change from
/// quietly moving this connection onto a socket.
///
/// `-c check_for_update_on_startup=false` leads, as a global option must sit
/// left of the `app-server` subcommand. The app-server does not itself check
/// for updates (only the TUI does, in `tui/src/updates.rs`), so this is a
/// belt-and-braces override on an always-internal process: a Codex Karmashala
/// spawns never runs the startup update check that behavioural antivirus reads
/// as a dropper signal (docs/windows-antivirus.md). Unconditional because the
/// app-server is never a session the user watches; the per-session setting
/// governs the interactive launches.
const List<String> codexAppServerArguments = [
  '-c',
  'check_for_update_on_startup=false',
  'app-server',
  '--listen',
  'stdio://',
];

/// How to reach one environment's `codex app-server`, as **plain data**.
///
/// Store scans run on the `karmashala.store-scan` worker isolate, where neither
/// the Riverpod providers nor the DAOs exist — and a live `Process` cannot cross
/// an isolate boundary, so the spawn has to happen over there. So the two cheap
/// DAO reads that answer "which Codex, and where" happen on the main isolate and
/// their answer crosses as this; the worker turns it back into a runner with
/// `CommandRunnerFactory`, which is what keeps Windows and WSL one code path.
class CodexAppServerLaunch {
  const CodexAppServerLaunch({
    required this.environment,
    required this.executable,
  });

  /// Where Codex runs. `CommandRunnerFactory` maps it to a `wsl.exe -d …`
  /// invocation for a WSL install and to the executable itself for a local one.
  final ExecutionEnvironment environment;

  /// The `codex` executable, spelled the way [environment] spells it.
  final String executable;

  String get environmentId => environment.id;

  @override
  String toString() => 'CodexAppServerLaunch(${environment.id}, $executable)';
}
