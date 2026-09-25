import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';

import '../domain/unattended_gate.dart';

/// Where an unattended run would happen, looked up now: the checkout, the
/// installation, what its agent declares, and whether its environment can be
/// reached. The app answers from its providers, the session host from the
/// store.
abstract interface class CheckoutFacts {
  Repository? repository(String id);

  AgentInstallation? installation(String id);

  /// What [agentId] declares, or null for an agent this build does not know.
  AgentDescriptor? descriptor(String agentId);

  /// Where [path]'s commands run, in the gate's vocabulary, with the
  /// resolver's own sentence when it cannot say.
  ({UnattendedReach reach, String reason}) reach(EnvironmentPath? path);

  /// The mode resuming a session of [agentId] would run in, [sessionMode]
  /// first and the user's default after.
  PermissionSelection resumePermission(String agentId, String? sessionMode);
}
