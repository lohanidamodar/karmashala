import 'package:agent_cli/descriptors.dart';

/// Which agents the Explorer is showing. A *filter*, not a section: a section
/// groups, so a "Codex" section would take a red-build row *away* from "Checks
/// failing". The empty set means every agent, so the last untick is a way back.
class AgentFilter {
  const AgentFilter(this.agentIds);

  /// The unfiltered list — what the Explorer shows when nobody has chosen.
  static const AgentFilter all = AgentFilter(<String>{});

  /// The `AgentDescriptor.id`s the user picked. Empty is [isUnfiltered].
  final Set<String> agentIds;

  bool get isUnfiltered => agentIds.isEmpty;

  /// Whether a session run by [agentId] is shown. Null is shown, always: null
  /// means the workspace cannot say which agent it is, and such a row can never
  /// be ticked in the menu, so hiding it would leave no way to get it back.
  bool allows(String? agentId) =>
      agentIds.isEmpty || agentId == null || agentIds.contains(agentId);

  /// This filter with [agentId] added if absent, removed if present.
  AgentFilter toggled(String agentId) => AgentFilter({
    for (final id in agentIds)
      if (id != agentId) id,
    if (!agentIds.contains(agentId)) agentId,
  });

  @override
  bool operator ==(Object other) =>
      other is AgentFilter &&
      other.agentIds.length == agentIds.length &&
      other.agentIds.containsAll(agentIds);

  @override
  int get hashCode => Object.hashAllUnordered(agentIds);

  @override
  String toString() =>
      'AgentFilter(${agentIds.isEmpty ? 'all' : agentIds.join(', ')})';
}

/// The agents the filter can name, in registry order — built from the registry,
/// not a sweep: an agent it does not list is one [AgentFilter.allows] never hides.
List<String> filterableAgentIds(AgentRegistry registry) => [
  for (final descriptor in registry.descriptors) descriptor.id,
];

/// What the funnel is doing, in one sentence, naming both halves so a filtered
/// Explorer does not read as a lost session. Names rather than a count: a count
/// of hidden rows would sweep the whole session table.
String agentFilterTooltip(AgentFilter filter, AgentRegistry registry) {
  if (filter.isUnfiltered) return 'Filter sessions';
  final shown = <String>[];
  final hidden = <String>[];
  for (final id in filterableAgentIds(registry)) {
    (filter.agentIds.contains(id) ? shown : hidden).add(
      registry.displayNameFor(id),
    );
  }
  // A filter naming an agent this registry has never heard of. Said rather than
  // dropped, so the menu's ticks and this sentence cannot disagree.
  for (final id in filter.agentIds) {
    if (registry.byId(id) == null) shown.add(id);
  }
  final showing = 'Showing ${_and(shown)} only';
  return hidden.isEmpty ? showing : '$showing — ${_and(hidden)} hidden';
}

/// `a`, `a and b`, `a, b and c` — the list as a sentence reads it.
String _and(List<String> names) => switch (names.length) {
  0 => 'nothing',
  1 => names.first,
  _ => '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}',
};
