import 'agent_descriptor.dart';

/// The variables of [environment] that [descriptor]'s CLI sets for its own
/// children, to withhold from a pane it launches (see
/// `AgentLaunchSpec.parentSessionEnvironment`). Empty for an unknown agent.
Set<String> inheritedParentSession(
  AgentDescriptor? descriptor,
  Map<String, String> environment,
) => {
  for (final name
      in descriptor?.launch.parentSessionEnvironment ?? const <String>{})
    if (environment.containsKey(name)) name,
};
