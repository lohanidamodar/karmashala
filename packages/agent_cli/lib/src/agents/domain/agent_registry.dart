import '../adapter/agent_adapter.dart';
import '../adapter/built_in_agent_adapters.dart';
import './agent_descriptor.dart';

/// The set of agents the app knows about, in probe/display order.
///
/// A registry of **adapters**: everything agent-specific is reached through
/// one, so a new agent is a new `AgentAdapter` registered here rather than a
/// code change in each place that used to ask who the agent was.
class AgentRegistry {
  const AgentRegistry(this.adapters);

  /// The agents shipped with the app.
  static const AgentRegistry builtIn = AgentRegistry(builtInAgentAdapters);

  /// The shipped agents plus [extra] — the person-added ACP agents a server
  /// keeps as rows. On a repeated id the later adapter wins, in the earlier
  /// one's place; [builtIn] itself is untouched.
  static AgentRegistry withExtra(Iterable<AgentAdapter> extra) {
    final byId = <String, AgentAdapter>{};
    for (final adapter in builtInAgentAdapters.followedBy(extra)) {
      byId[adapter.id] = adapter;
    }
    return AgentRegistry(List.unmodifiable(byId.values));
  }

  final List<AgentAdapter> adapters;

  /// Each adapter's descriptor, in registry order.
  List<AgentDescriptor> get descriptors => [
    for (final adapter in adapters) adapter.descriptor,
  ];

  AgentAdapter? adapterFor(String id) {
    for (final adapter in adapters) {
      if (adapter.id == id) return adapter;
    }
    return null;
  }

  AgentDescriptor? byId(String id) => adapterFor(id)?.descriptor;

  /// A human-readable name for [id], falling back to the raw id for an agent
  /// this registry has never heard of (e.g. a stored installation whose
  /// descriptor was removed).
  String displayNameFor(String id) => byId(id)?.displayName ?? id;
}
