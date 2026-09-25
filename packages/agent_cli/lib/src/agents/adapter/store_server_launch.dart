import '../../environments/execution_environment.dart';

/// How to reach one environment's agent store server, as **plain data**.
///
/// Store scans run on the `karmashala.store-scan` worker isolate, where neither
/// the Riverpod providers nor the DAOs exist — and a live `Process` cannot cross
/// an isolate boundary, so the spawn has to happen over there. So the two cheap
/// DAO reads that answer "which CLI, and where" happen on the main isolate and
/// their answer crosses as this; the worker turns it back into a runner with
/// `CommandRunnerFactory`, which is what keeps Windows and WSL one code path.
class StoreServerLaunch {
  const StoreServerLaunch({
    required this.environment,
    required this.executable,
  });

  /// Where the CLI runs. `CommandRunnerFactory` maps it to a `wsl.exe -d …`
  /// invocation for a WSL install and to the executable itself for a local one.
  final ExecutionEnvironment environment;

  /// The CLI's executable, spelled the way [environment] spells it.
  final String executable;

  String get environmentId => environment.id;

  @override
  String toString() => 'StoreServerLaunch(${environment.id}, $executable)';
}
