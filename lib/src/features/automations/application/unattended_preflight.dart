import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_permission_options.dart';
import '../../environments/application/environment_resolver.dart';
import '../../repositories/application/repository_providers.dart';
import '../domain/automation.dart';
import '../domain/unattended_gate.dart';
import 'automation_providers.dart';

/// The one place a scheduled or queued fire is checked against the unattended
/// rules before an agent is started.
///
/// **Only lookups.** The rules are in `domain/unattended_gate.dart` and are
/// pure; this reads the checkout, the installation and the environment and
/// hands them over. Every unattended entry point comes through here — the arm
/// form, the timer, the queue drain — so an automation cannot be refused by one
/// path and armed by another, and the sentence a person sees on hover is the
/// sentence the write path throws.
class UnattendedPreflight {
  const UnattendedPreflight(this._ref);

  final Ref _ref;

  /// The gate's inputs for [automation], looked up now.
  ///
  /// Deliberately re-read on every call rather than cached: **arming-time
  /// preconditions lapse**. A checkout's checks are deleted, an agent is
  /// uninstalled, an SSH host stops being reachable — and the fire is the
  /// moment that matters, not the arming.
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
    // default — and the gate then reads that default's rung like any other.
    // It is not the same as `PermissionSelection.empty`, which enforces
    // nothing and is refused.
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

  /// The resolver's answer, in the gate's vocabulary.
  ///
  /// `sshUnavailable` is exactly *"this app cannot reach where the agent would
  /// run"*; the other two refusals are *"nothing says where it would run"*.
  /// Mapped here rather than in the gate so the rules stay free of the
  /// resolver's own type — and the resolver's sentence is carried through
  /// verbatim, so the two cannot drift.
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
///
/// A `Provider.family` so a card can watch it: a check added, an agent repaired
/// or a host reached makes the refusal disappear without anything asking again
/// on a timer.
///
/// **Keyed by the id, not by the [Automation].** The row is read fresh out of
/// the DAO on every revision and `Automation` is not a value type, so a family
/// keyed by the object would mint a new entry per rebuild and keep every one of
/// them alive.
final automationRefusalProvider =
    Provider.family<UnattendedRefusal?, String>((ref, automationId) {
      ref.watch(automationsRevisionProvider);
      final automation = ref.read(automationDaoProvider).getById(automationId);
      if (automation == null) return null;
      return ref.read(unattendedPreflightProvider).refusalFor(automation);
    });
