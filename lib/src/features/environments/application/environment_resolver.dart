import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_factory.dart';
import '../../../core/process/command_runner_providers.dart';
import '../data/execution_environment_dao.dart';
import '../domain/environment_kind.dart';
import '../domain/environment_path.dart';
import '../domain/execution_environment.dart';
import 'environment_providers.dart';

/// Why the environment a checkout's commands would run in could not be named.
///
/// Each value is a different thing to tell the user, which is why they are not
/// one "unknown": a missing row is a workspace that lost an environment, a
/// nameless WSL row is a distribution that went away, and an SSH row with
/// nothing to dial it is this app composed without a connection pool.
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
/// said.
///
/// A refusal is a **value the caller shows**, not an exception that becomes
/// "Unknown environment: …" in a log. Sites that already throw keep throwing,
/// with [reason] as the message, so the two cannot drift.
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

/// The one answer to *"where does a command for this checkout run?"*.
///
/// Every launch path used to answer it alone — a `getById`, a null check and a
/// sentence of its own — so the same failure read four different ways and a
/// fifth path could invent a fifth. The runner half was already central
/// ([CommandRunnerFactory.forEnvironment]); this is the half that decides which
/// environment to hand it.
///
/// [runners] is asked whether a remote environment is reachable at all, so an
/// SSH checkout in a container composed without a connection pool is refused
/// here — with words — rather than throwing out of the factory later.
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

  /// As [resolveFor], for a caller holding only an id.
  ///
  /// [runnable] asks the stronger question: not just *which* environment, but
  /// whether this app can run a command there. Turn it off for callers that
  /// need the environment's shape alone — a command line to copy, a path to
  /// spell — where nothing is spawned and reachability is not the question.
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
