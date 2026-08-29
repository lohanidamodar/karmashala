import 'agent_descriptor.dart';
import 'agent_kind.dart';
import 'built_in_agents.dart';

/// The set of agents the app knows about, in probe/display order.
///
/// Discovery, CLI-store location and status detection all read this instead of
/// hardcoding agent facts, so a new agent is a new [AgentDescriptor] rather than
/// a code change in each of those places.
class AgentRegistry {
  const AgentRegistry(this.descriptors);

  /// The agents shipped with the app.
  static const AgentRegistry builtIn = AgentRegistry(builtInAgentDescriptors);

  final List<AgentDescriptor> descriptors;

  AgentDescriptor? byId(String id) {
    for (final descriptor in descriptors) {
      if (descriptor.id == id) return descriptor;
    }
    return null;
  }

  /// The descriptor for a legacy [AgentKind], or `null` if this registry has
  /// no entry for it.
  AgentDescriptor? forKind(AgentKind kind) {
    for (final descriptor in descriptors) {
      if (descriptor.kind == kind) return descriptor;
    }
    return null;
  }
}
