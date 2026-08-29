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

  /// A human-readable name for [id], falling back to the raw id for an agent
  /// this registry has never heard of (e.g. a stored installation whose
  /// descriptor was removed).
  String displayNameFor(String id) => byId(id)?.displayName ?? id;

  /// The descriptor for the [AgentKind] of an agent that has a protocol
  /// adapter, or `null` if this registry has no entry for it.
  AgentDescriptor? forKind(AgentKind kind) {
    for (final descriptor in descriptors) {
      if (descriptor.kind == kind) return descriptor;
    }
    return null;
  }
}
