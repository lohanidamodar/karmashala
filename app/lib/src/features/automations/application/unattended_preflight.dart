import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/runner.dart';
import 'package:karmashala_automations/unattended.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart';
import 'package:riverpod/riverpod.dart';

import '../../agents/application/agent_providers.dart';
import '../../environments/application/environment_resolver.dart';
import '../../repositories/application/repository_providers.dart';
import '../../sessions/application/session_launcher.dart';
import 'automation_providers.dart';

export 'package:karmashala_automations/runner.dart' show UnattendedPreflight;

/// What the app knows about a checkout, from its providers: the one resolver
/// for reach and the launcher's own rule for a resume's mode.
class AppCheckoutFacts implements CheckoutFacts {
  const AppCheckoutFacts(this._ref);

  final Ref _ref;

  @override
  Repository? repository(String id) =>
      _ref.read(repositoryDaoProvider).getById(id);

  @override
  AgentInstallation? installation(String id) =>
      _ref.read(agentInstallationDaoProvider).getById(id);

  @override
  AgentDescriptor? descriptor(String agentId) =>
      _ref.read(agentRegistryProvider).byId(agentId);

  @override
  PermissionSelection resumePermission(String agentId, String? sessionMode) =>
      _ref
          .read(sessionLauncherProvider)
          .permissionFor(
            agentId,
            SessionPurpose.existingSession,
            sessionMode: sessionMode,
          );

  @override
  ({UnattendedReach reach, String reason}) reach(EnvironmentPath? path) {
    final resolution = _ref
        .read(environmentResolverProvider)
        .resolveFor(path, runnable: true);
    return (reach: _reachOf(resolution), reason: resolution.reason);
  }

  static UnattendedReach _reachOf(EnvironmentResolution resolution) =>
      switch (resolution.refusal) {
        null => UnattendedReach.reachable,
        EnvironmentRefusal.sshUnavailable => UnattendedReach.unreachable,
        EnvironmentRefusal.noCheckout ||
        EnvironmentRefusal.environmentUnknown ||
        EnvironmentRefusal.wslDistributionUnknown => UnattendedReach.unnamed,
      };
}

final checkoutFactsProvider = Provider<CheckoutFacts>(AppCheckoutFacts.new);

/// The one place a fire is checked against the unattended rules.
final unattendedPreflightProvider = Provider<UnattendedPreflight>(
  (ref) => UnattendedPreflight(
    facts: ref.watch(checkoutFactsProvider),
    checks: ref.watch(projectCheckDaoProvider),
  ),
);

/// Why the automation with this id cannot be armed or fired right now, or null.
/// Keyed by the id: `Automation` is not a value type, so it would leak entries.
final automationRefusalProvider = Provider.family<UnattendedRefusal?, String>((
  ref,
  automationId,
) {
  ref.watch(automationsRevisionProvider);
  final automation = ref.read(automationDaoProvider).getById(automationId);
  // A message rule starts no agent; its gate is the target session's.
  if (automation == null || !automation.startsAgent) return null;
  return ref.read(unattendedPreflightProvider).refusalFor(automation);
});
