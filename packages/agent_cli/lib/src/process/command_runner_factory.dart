import '../environments/environment_kind.dart';
import '../environments/execution_environment.dart';
import 'command_runner.dart';
import 'local_command_runner.dart';
import 'wsl_command_runner.dart';

/// Creates the right [CommandRunner] for a given execution environment.
///
/// Centralizes the environment-kind → runner mapping so callers ask for "a
/// runner for this environment" instead of constructing `Process`-backed
/// runners themselves. Overridable in tests to return a fake.
///
/// **This package knows two kinds of environment: this machine, and a WSL
/// distribution on it.** SSH is deliberately absent — reaching another machine
/// means a connection, a key and somewhere to keep both, which is the host
/// application's business and not a coding CLI's. Karmashala subclasses this
/// and adds an `EnvironmentKind.ssh` case; the
/// [unsupported] hook is what lets a subclass answer for a kind this package
/// cannot place, instead of this class having to know it exists.
class CommandRunnerFactory {
  const CommandRunnerFactory();

  /// Whether an environment this package cannot place can be run in at all.
  ///
  /// False here, because the only such kind is SSH and this package has no
  /// transport for it. A subclass that adds one overrides this, and callers
  /// ask before handing out a remote environment so a composition without a
  /// transport refuses in words rather than throwing later.
  bool get canReachRemote => false;

  CommandRunner forEnvironment(ExecutionEnvironment environment) {
    switch (environment.kind) {
      case EnvironmentKind.windowsNative:
      case EnvironmentKind.localPosix:
        return const LocalCommandRunner();
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
        return unsupported(environment);
    }
  }

  /// The runner for an environment this factory has no transport for.
  ///
  /// Throws here; a subclass overrides it rather than re-implementing
  /// [forEnvironment], so the local and WSL cases cannot drift between the two.
  CommandRunner unsupported(ExecutionEnvironment environment) {
    throw StateError(
      'No transport for ${environment.kind.name} environment '
      '${environment.id}; agent_cli runs commands locally and in WSL only.',
    );
  }
}

/// Resolves an environment id to the runner that reaches it.
///
/// **The seam that broke the package's last edge back into the app.** Every
/// adapter used to hold a [CommandRunnerFactory] *and* an environment DAO *and*
/// a Riverpod-backed resolver, which is three ways of saying "give me a runner
/// for this id" and dragged a database in behind each. One function says it
/// once, and the host composes it out of whatever it keeps environments in.
typedef RunnerResolver = CommandRunner Function(String environmentId);

/// A [RunnerResolver] over a fixed list of environments.
///
/// What a caller with the environments already in hand uses; the app's own
/// resolver reads them from its database instead.
RunnerResolver runnerResolverFor(
  List<ExecutionEnvironment> environments, {
  CommandRunnerFactory factory = const CommandRunnerFactory(),
}) => (String environmentId) {
  for (final environment in environments) {
    if (environment.id == environmentId) {
      return factory.forEnvironment(environment);
    }
  }
  throw StateError('Unknown execution environment "$environmentId"');
};
