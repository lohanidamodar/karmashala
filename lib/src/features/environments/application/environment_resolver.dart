import 'package:riverpod/riverpod.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../data/execution_environment_dao.dart';
import 'environment_providers.dart';

/// Why the environment a checkout's commands would run in could not be named.
/// Each value is a different thing to tell the user, which is why it is not one.
enum EnvironmentRefusal {
  /// Nothing named a directory at all — no project, no repository row, no
  /// recorded working directory.
  noCheckout,

  /// The id is there and the row it points at is not.
  environmentUnknown,

  /// A WSL row that no longer carries the distribution it is for.
  wslDistributionUnknown,

  /// An SSH row with no connection pool composed to reach it.
  sshUnavailable,
}

/// Where a command for one checkout runs — or the worded reason it cannot be
/// said. A refusal is a **value the caller shows**, not an exception.
class EnvironmentResolution {
  const EnvironmentResolution.resolved(ExecutionEnvironment this.environment)
    : refusal = null,
      reason = '';

  const EnvironmentResolution.refused(
    EnvironmentRefusal this.refusal,
    this.reason,
  ) : environment = null;

  /// Where commands run, or null when this is a refusal.
  final ExecutionEnvironment? environment;

  /// Null when resolved.
  final EnvironmentRefusal? refusal;

  /// One sentence, empty when resolved. Fit to show and to throw with.
  final String reason;

  bool get isResolved => environment != null;

  /// The environment, for a caller that has already refused on its own terms.
  ExecutionEnvironment get require {
    final env = environment;
    if (env == null) throw StateError(reason);
    return env;
  }

  @override
  String toString() =>
      isResolved ? 'EnvironmentResolution($environment)' : 'refused: $reason';
}

/// The one answer to *"where does a command for this checkout run?"*. [runners]
/// is asked whether a remote environment is reachable, so SSH is refused here.
class ExecutionEnvironmentResolver {
  const ExecutionEnvironmentResolver({
    required this.environments,
    required this.runners,
  });

  final ExecutionEnvironmentDao environments;
  final CommandRunnerFactory runners;

  /// The environment [path]'s commands run in, or why that cannot be said.
  EnvironmentResolution resolveFor(EnvironmentPath? path, {bool runnable = true}) =>
      resolve(path?.environmentId, runnable: runnable);

  /// As [resolveFor], for a caller holding only an id. [runnable] asks the
  /// stronger question — turn it off where nothing is spawned.
  EnvironmentResolution resolve(String? environmentId, {bool runnable = true}) {
    if (environmentId == null || environmentId.isEmpty) {
      return const EnvironmentResolution.refused(
        EnvironmentRefusal.noCheckout,
        'No checkout, so nothing says where its commands would run',
      );
    }
    final environment = environments.getById(environmentId);
    if (environment == null) {
      return EnvironmentResolution.refused(
        EnvironmentRefusal.environmentUnknown,
        'Unknown environment: $environmentId',
      );
    }
    switch (environment.kind) {
      case EnvironmentKind.windowsNative:
      case EnvironmentKind.localPosix:
        break;
      case EnvironmentKind.wsl:
        final distro = environment.wslDistribution;
        if (distro == null || distro.isEmpty) {
          return EnvironmentResolution.refused(
            EnvironmentRefusal.wslDistributionUnknown,
            'WSL environment $environmentId has no distribution name',
          );
        }
      case EnvironmentKind.ssh:
        if (runnable && !runners.canReachRemote) {
          return EnvironmentResolution.refused(
            EnvironmentRefusal.sshUnavailable,
            'No SSH connection pool is configured; cannot run commands in '
            '$environmentId',
          );
        }
    }
    return EnvironmentResolution.resolved(environment);
  }
}

/// The resolver, wired to the workspace's environments and its runner factory.
final environmentResolverProvider = Provider<ExecutionEnvironmentResolver>(
  (ref) => ExecutionEnvironmentResolver(
    environments: ref.watch(executionEnvironmentDaoProvider),
    runners: ref.watch(commandRunnerFactoryProvider),
  ),
);

/// The `RunnerResolver` `agent_cli` asks for: an environment id in, the runner
/// that reaches it out. One function instead of three ways of saying it.
final runnerResolverProvider = Provider<RunnerResolver>((ref) {
  final resolver = ref.watch(environmentResolverProvider);
  final runners = ref.watch(commandRunnerFactoryProvider);
  return (environmentId) =>
      runners.forEnvironment(resolver.resolve(environmentId).require);
});
