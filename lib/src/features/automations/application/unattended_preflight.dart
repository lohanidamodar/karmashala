import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_resolver.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_launcher.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/session.dart';
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
  UnattendedGateInput inputFor(Automation automation) => _input(
    repositoryId: automation.repositoryId,
    agentInstallationId: automation.agentInstallationId,
    // Null means "nobody chose", which resolves to the agent's declared
    // default; not the same as `PermissionSelection.empty`, which is refused.
    selectionOf: (agentId, support) =>
        support.resolveStored(automation.permissionMode?.canonical),
    missingCheckout:
        'This automation names a checkout that is no longer in the workspace',
  );

  /// The gate's inputs for resuming [session] with nobody watching, under
  /// [permissionMode] or, when null, the mode the session would resume in.
  UnattendedGateInput inputForResume(
    Session session, {
    String? permissionMode,
  }) => _input(
    repositoryId: session.repositoryId,
    agentInstallationId: session.agentInstallationId,
    selectionOf: (agentId, _) => _ref
        .read(sessionLauncherProvider)
        .permissionFor(
          agentId,
          SessionPurpose.existingSession,
          sessionMode: permissionMode ?? session.permissionMode,
        ),
    missingCheckout:
        'This session names a checkout that is no longer in the workspace',
    requiresChecks: false,
  );

  UnattendedGateInput _input({
    required String repositoryId,
    required String agentInstallationId,
    required PermissionSelection Function(
      String agentId,
      AgentPermissionSupport support,
    )
    selectionOf,
    required String missingCheckout,
    bool requiresChecks = true,
  }) {
    final repository = _ref.read(repositoryDaoProvider).getById(repositoryId);
    final checks = _ref.read(projectCheckDaoProvider);
    final installation = _ref
        .read(agentInstallationDaoProvider)
        .getById(agentInstallationId);
    final registry = _ref.read(agentRegistryProvider);
    final descriptor = installation == null
        ? null
        : registry.byId(installation.agentId);
    final support = descriptor?.launch.permission;
    final selection = support == null
        ? null
        : selectionOf(installation!.agentId, support);

    final resolution = repository == null
        ? EnvironmentResolution.refused(
            EnvironmentRefusal.noCheckout,
            missingCheckout,
          )
        : _ref
              .read(environmentResolverProvider)
              .resolveFor(repository.path, runnable: true);

    return UnattendedGateInput(
      repositoryName: repository?.name ?? '',
      verificationEnabled:
          repository != null && checks.isVerificationEnabled(repository.id),
      projectCheckCount: repository == null
          ? 0
          : checks.countFor(repository.id),
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
      requiresChecks: requiresChecks,
    );
  }

  /// Why [automation] may not fire unattended, or `null` when it may.
  UnattendedRefusal? refusalFor(Automation automation) =>
      unattendedRefusal(inputFor(automation));

  /// Why [session] may not be resumed unattended, or `null` when it may.
  UnattendedRefusal? refusalForResume(
    Session session, {
    String? permissionMode,
  }) => unattendedRefusal(
    inputForResume(session, permissionMode: permissionMode),
  );

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
final automationRefusalProvider = Provider.family<UnattendedRefusal?, String>((
  ref,
  automationId,
) {
  ref.watch(automationsRevisionProvider);
  final automation = ref.read(automationDaoProvider).getById(automationId);
  if (automation == null) return null;
  return ref.read(unattendedPreflightProvider).refusalFor(automation);
});
