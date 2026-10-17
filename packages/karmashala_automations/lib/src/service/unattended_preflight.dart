import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_session/session.dart';

import '../domain/automation.dart';
import '../domain/unattended_gate.dart';

import 'checkout_facts.dart';

/// The one place a fire is checked against the unattended rules — lookups
/// only, so no path can refuse where another would arm.
class UnattendedPreflight {
  const UnattendedPreflight({required this._facts});

  final CheckoutFacts _facts;

  /// The gate's inputs for [automation], re-read on every call.
  UnattendedGateInput inputFor(Automation automation) => _input(
    repositoryId: automation.repositoryId,
    agentInstallationId: automation.agentInstallationId,
    // Null is "nobody chose" — the agent's declared default, not empty.
    selectionOf: (agentId, support) =>
        support.resolveStored(automation.permissionMode?.canonical),
    missingCheckout:
        'This automation names a checkout that is no longer in the workspace',
  );

  /// The gate's inputs for resuming [session] with nobody watching.
  UnattendedGateInput inputForResume(
    Session session, {
    String? permissionMode,
  }) => _input(
    repositoryId: session.repositoryId,
    agentInstallationId: session.agentInstallationId,
    selectionOf: (agentId, _) => _facts.resumePermission(
      agentId,
      permissionMode ?? session.permissionMode,
    ),
    missingCheckout:
        'This session names a checkout that is no longer in the workspace',
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
  }) {
    final repository = _facts.repository(repositoryId);
    final installation = _facts.installation(agentInstallationId);
    final descriptor = installation == null
        ? null
        : _facts.descriptor(installation.agentId);
    final support = descriptor?.launch.permission;
    final selection = support == null
        ? null
        : selectionOf(installation!.agentId, support);
    final reach = repository == null
        ? (reach: UnattendedReach.unnamed, reason: missingCheckout)
        : _facts.reach(repository.path);

    return UnattendedGateInput(
      repositoryName: repository?.name ?? '',
      agentName:
          descriptor?.displayName ??
          installation?.agentId ??
          'the agent this automation was set up with',
      agentInstalled: installation != null,
      permits: support?.riskOf(selection),
      permissionLabel: support == null
          ? ''
          : describeSelection(support, selection),
      permissionEvidence: support?.evidence ?? '',
      reach: reach.reach,
      reachReason: reach.reason,
    );
  }

  /// Why [automation] may not fire unattended, or `null` when it may. A
  /// command starts no agent, so only where it runs is asked.
  UnattendedRefusal? refusalFor(Automation automation) => automation.runsCommand
      ? _placeRefusal(automation)
      : unattendedRefusal(inputFor(automation));

  UnattendedRefusal? _placeRefusal(Automation automation) {
    final path =
        automation.folder ?? _facts.repository(automation.repositoryId)?.path;
    if (path == null) {
      return const UnattendedRefusal(
        UnattendedRefusalKind.environmentUnnamed,
        'This automation names a checkout that is no longer in the workspace',
      );
    }
    final reach = _facts.reach(path);
    return switch (reach.reach) {
      UnattendedReach.reachable => null,
      UnattendedReach.unnamed => UnattendedRefusal(
        UnattendedRefusalKind.environmentUnnamed,
        reach.reason,
      ),
      UnattendedReach.unreachable => UnattendedRefusal(
        UnattendedRefusalKind.environmentUnreachable,
        reach.reason,
      ),
    };
  }

  /// Why [session] may not be resumed unattended, or `null` when it may.
  UnattendedRefusal? refusalForResume(
    Session session, {
    String? permissionMode,
  }) => unattendedRefusal(
    inputForResume(session, permissionMode: permissionMode),
  );
}
