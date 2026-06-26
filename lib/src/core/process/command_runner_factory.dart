import '../../features/environments/domain/environment_kind.dart';
import '../../features/environments/domain/execution_environment.dart';
import 'command_runner.dart';
import 'windows_command_runner.dart';
import 'wsl_command_runner.dart';

/// Creates the right [CommandRunner] for a given execution environment.
///
/// Centralizes the environment-kind → runner mapping so features ask for "a
/// runner for this environment" instead of constructing `Process`-backed runners
/// themselves. Overridable in tests to return a `FakeCommandRunner`.
class CommandRunnerFactory {
  const CommandRunnerFactory();

  CommandRunner forEnvironment(ExecutionEnvironment environment) {
    switch (environment.kind) {
      case EnvironmentKind.windowsNative:
        return const WindowsCommandRunner();
      case EnvironmentKind.wsl:
        final distro = environment.wslDistribution;
        if (distro == null) {
          throw ArgumentError(
            'WSL environment ${environment.id} has no distribution name',
          );
        }
        return WslCommandRunner(
          environmentId: environment.id,
          distribution: distro,
        );
    }
  }
}
