import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../data/agent_discovery_service.dart';
import '../data/agent_probe_log.dart';
import '../domain/agent_installation.dart';
import 'agent_providers.dart';

/// Holds the known agent installations and can (re)discover them across every
/// known execution environment.
class AgentInstallationsController extends Notifier<List<AgentInstallation>> {
  @override
  List<AgentInstallation> build() =>
      ref.watch(agentInstallationDaoProvider).getAll();

  /// Probes every known environment for installed agents and persists any not
  /// already recorded (matched by natural identity). Returns the total set of
  /// installations discovered this run.
  Future<List<AgentInstallation>> discoverAll() async {
    final environments = ref.read(executionEnvironmentDaoProvider).getAll();
    final factory = ref.read(commandRunnerFactoryProvider);
    final dao = ref.read(agentInstallationDaoProvider);
    final ids = ref.read(idGeneratorProvider);
    final clock = ref.read(clockProvider);
    final registry = ref.read(agentRegistryProvider);
    final log = AgentProbeLog(ref.read(databaseProvider));

    final discovered = <AgentInstallation>[];
    for (final environment in environments) {
      final runner = factory.forEnvironment(environment);
      final found = await AgentDiscoveryService(
        runner: runner,
        environment: environment,
        ids: ids,
        clock: clock,
        registry: registry,
      ).discover();
      for (final installation in found) {
        discovered.add(installation);
        final existing = dao.getByIdentity(
          installation.agentId,
          installation.environmentId,
          installation.executable.path,
        );
        if (existing == null) dao.insert(installation);
      }
      // This walk asked about every agent, so [discoverUnprobed] need not ask
      // again. Not recorded for a remote host: discovery cannot tell an
      // unreachable machine from an empty one, so "we looked" would be a claim
      // about a connection that may never have happened.
      if (environment.kind != EnvironmentKind.ssh) {
        for (final descriptor in registry.descriptors) {
          log.record(descriptor.id, environment.id, clock.nowUtc());
        }
      }
    }

    state = dao.getAll();
    return discovered;
  }

  /// Probes only the `(agent, environment)` pairs nobody has ever searched for,
  /// and returns the installations that search turned up.
  ///
  /// This is what makes an agent added by an *app upgrade* visible. Discovery
  /// used to run exactly once, when the workspace was created, so a descriptor
  /// that joined the registry later — `antigravity` in 1.1.4 — was invisible
  /// until the user happened to find "Discover agents" in Settings.
  ///
  /// **What counts as already searched**, in the order it is checked:
  ///
  /// * an installation row for that pair — the row is itself proof somebody
  ///   looked, and re-probing every known agent on every launch is the cost
  ///   this whole method exists to avoid;
  /// * an [AgentProbeLog] entry — which is how a *miss* stops repeating. An
  ///   agent that is genuinely not installed is searched for once, ever.
  ///
  /// SSH environments are skipped and, deliberately, **not** recorded as
  /// searched: probing one means dialling somebody's machine, which is not
  /// something a launch should do unasked, and pretending we looked would stop
  /// the manual per-environment scan from ever doing it.
  ///
  /// The cost is self-extinguishing. The first run after an upgrade spawns one
  /// process per genuinely-new pair; every run after that spawns none.
  Future<List<AgentInstallation>> discoverUnprobed() async {
    final dao = ref.read(agentInstallationDaoProvider);
    final registry = ref.read(agentRegistryProvider);
    final log = AgentProbeLog(ref.read(databaseProvider));
    final clock = ref.read(clockProvider);
    final factory = ref.read(commandRunnerFactoryProvider);
    final ids = ref.read(idGeneratorProvider);

    final discovered = <AgentInstallation>[];
    for (final environment in ref
        .read(executionEnvironmentDaoProvider)
        .getAll()) {
      if (environment.kind == EnvironmentKind.ssh) continue;
      final known = {
        for (final install in dao.getByEnvironment(environment.id))
          install.agentId,
      };
      final missing = {
        for (final descriptor in registry.descriptors)
          if (!known.contains(descriptor.id) &&
              !log.hasProbed(descriptor.id, environment.id))
            descriptor.id,
      };
      // No runner, no subprocess, nothing: the common case after the first
      // sweep is an environment with nothing left to ask about.
      if (missing.isEmpty) continue;

      final found = await AgentDiscoveryService(
        runner: factory.forEnvironment(environment),
        environment: environment,
        ids: ids,
        clock: clock,
        registry: registry,
      ).discover(agentIds: missing);

      for (final installation in found) {
        if (dao.getByIdentity(
              installation.agentId,
              installation.environmentId,
              installation.executable.path,
            ) ==
            null) {
          dao.insert(installation);
        }
        discovered.add(installation);
      }
      // Every pair that was actually asked about, found or not.
      for (final agentId in missing) {
        log.record(agentId, environment.id, clock.nowUtc());
      }
    }

    state = dao.getAll();
    return discovered;
  }
}

final agentInstallationsControllerProvider =
    NotifierProvider<AgentInstallationsController, List<AgentInstallation>>(
      AgentInstallationsController.new,
    );

/// Resolves the default installation to use from [installs]: the specific one
/// pinned by [defaultInstallationId] if still present, else the first
/// installation of [defaultAgentId], else `null`.
AgentInstallation? resolveDefaultInstallation(
  List<AgentInstallation> installs, {
  String? defaultInstallationId,
  String? defaultAgentId,
}) {
  if (defaultInstallationId != null) {
    for (final install in installs) {
      if (install.id == defaultInstallationId) return install;
    }
  }
  if (defaultAgentId != null) {
    for (final install in installs) {
      if (install.agentId == defaultAgentId) return install;
    }
  }
  return null;
}
