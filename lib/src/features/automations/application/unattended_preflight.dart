import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_resolver.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/automation.dart';
import '../domain/unattended_gate.dart';
import 'automation_providers.dart';

/// The one place a scheduled or queued fire is checked against the unattended
/// rules — lookups only, so no path can refuse where another would arm.
class UnattendedPreflight {
  const UnattendedPreflight(this._ref);

  final Ref _ref;

  /// The gate's inputs for [automation], looked up now. Re-read on every call
  /// rather than cached, because arming-time preconditions lapse.
  UnattendedGateInput inputFor(Automation automation) {
    final repository = _ref
        .read(repositoryDaoProvider)
        .getById(automation.repositoryId);
    final checks = _ref.read(projectCheckDaoProvider);
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(automation.agentInstallationId);
    final registry = _ref.read(agentRegistryProvider);
    final descriptor = installation == null
        ? null
        : registry.byId(installation.agentId);
    final support = descriptor?.launch.permission;

    // Null means "nobody chose", which resolves to the agent's declared
    // default; not the same as `PermissionSelection.empty`, which is refused.
    final selection = support?.resolveStored(
      automation.permissionMode?.canonical,
    );

    final resolution = repository == null
        ? const EnvironmentResolution.refused(
            EnvironmentRefusal.noCheckout,
            'This automation names a checkout that is no longer in the '
            'workspace',
          )
        : _ref
              .read(environmentResolverProvider)
              .resolveFor(repository.path, runnable: true);

    return UnattendedGateInput(
      repositoryName: repository?.name ?? '',
      verificationEnabled: repository != null &&
          checks.isVerificationEnabled(repository.id),
      projectCheckCount: repository == null ? 0 : checks.countFor(repository.id),
      agentName:
          descriptor?.displayName ??
          installation?.agentId ??
          'the agent this automation was armed on',
      agentInstalled: installation != null,
      permits: support?.riskOf(selection),
      permissionLabel: support == null
          ? ''
          : describeSelection(support, selection),
      permissionEvidence: support?.evidence ?? '',
      reach: _reachOf(resolution),
      reachReason: resolution.reason,
    );
  }

  /// Why [automation] may not fire unattended, or `null` when it may.
  UnattendedRefusal? refusalFor(Automation automation) =>
      unattendedRefusal(inputFor(automation));

  /// The resolver's answer in the gate's vocabulary, mapped here so the rules
  /// stay free of the resolver's type and its sentence is carried verbatim.
  static UnattendedReach _reachOf(EnvironmentResolution resolution) {
    switch (resolution.refusal) {
      case null:
        return UnattendedReach.reachable;
      case EnvironmentRefusal.sshUnavailable:
        return UnattendedReach.unreachable;
      case EnvironmentRefusal.noCheckout:
      case EnvironmentRefusal.environmentUnknown:
      case EnvironmentRefusal.wslDistributionUnknown:
        return UnattendedReach.unnamed;
    }
  }
}

final unattendedPreflightProvider = Provider<UnattendedPreflight>(
  UnattendedPreflight.new,
);

/// Why the automation with this id cannot be armed or fired right now, or null.
/// Keyed by the id: [Automation] is not a value type, so it would leak entries.
final automationRefusalProvider =
    Provider.family<UnattendedRefusal?, String>((ref, automationId) {
      ref.watch(automationsRevisionProvider);
      final automation = ref.read(automationDaoProvider).getById(automationId);
      if (automation == null) return null;
      return ref.read(unattendedPreflightProvider).refusalFor(automation);
    });
