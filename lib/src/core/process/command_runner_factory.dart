import '../../features/environments/domain/environment_kind.dart';
import '../../features/environments/domain/execution_environment.dart';
import '../../features/ssh/data/ssh_connection_pool.dart';
import 'command_runner.dart';
import 'ssh_command_runner.dart';
import 'windows_command_runner.dart';
import 'wsl_command_runner.dart';

/// Creates the right [CommandRunner] for a given execution environment.
///
/// Centralizes the environment-kind → runner mapping so features ask for "a
/// runner for this environment" instead of constructing `Process`-backed runners
/// themselves. Overridable in tests to return a `FakeCommandRunner`.
///
/// [sshConnections] supplies the shared connection an SSH runner needs. It is a
/// callback rather than a value so that composing the factory — which the whole
/// app does — never builds a connection pool, and therefore never touches the
/// database, unless a remote environment is actually asked for. It is optional
/// because most of the app is composed without one; asking for an SSH runner
/// without it is a wiring bug and fails loudly rather than connecting something
/// unconfigured.
class CommandRunnerFactory {
  const CommandRunnerFactory({this.sshConnections});

  final SshConnectionPool Function()? sshConnections;

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
      case EnvironmentKind.ssh:
        final pool = sshConnections?.call();
        if (pool == null) {
          throw StateError(
            'No SSH connection pool is configured; cannot run commands in '
            '${environment.id}',
          );
        }
        return SshCommandRunner(
          environmentId: environment.id,
          connection: pool.forEnvironment(environment),
        );
    }
  }
}
