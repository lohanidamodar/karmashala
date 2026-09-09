import 'package:agent_cli/descriptors.dart';

/// **Which agents the Explorer is showing.**
///
/// A *filter*, not a section, and the distinction is the whole design. A
/// section **groups**: [assignSections] hands each row to exactly one of them,
/// top to bottom, so a "Codex" section would take a red-build Codex session
/// *away* from "Checks failing" — the two would compete for the same row rather
/// than compose. A filter **hides**: it narrows the whole list, sections and
/// project tree alike, and the two questions stack. "Checks failing, among my
/// Codex sessions" is one section and one filter, and there is no arrangement
/// of sections that answers it.
///
/// The other half of the argument is arithmetic. The request was "agy only,
/// codex only, claude only, or two of them only" — that is every non-empty
/// subset of three agents, which is seven sections to maintain by hand and
/// fifteen at four agents. A set is one control.
///
/// **The empty set means "every agent", never "no agents".** Unticking the last
/// agent returns to the unfiltered list, which is the only reading that leaves
/// the control reversible: a filter whose natural end state is a blank sidebar
/// is a filter users learn to be afraid of.
class AgentFilter {
  const AgentFilter(this.agentIds);

  /// The unfiltered list — what the Explorer shows when nobody has chosen.
  static const AgentFilter all = AgentFilter(<String>{});

  /// The `AgentDescriptor.id`s the user picked. Empty is [isUnfiltered].
  final Set<String> agentIds;

  bool get isUnfiltered => agentIds.isEmpty;

  /// Whether a session run by [agentId] is shown.
  ///
  /// **Null is shown, always.** `null` here means *the workspace cannot say
  /// which agent this is* — a native session whose `agent_installations` row
  /// went away when the CLI was uninstalled (`AgentInstallationsController`
  /// deletes on reconcile, so this is an ordinary shape rather than corruption),
  /// or an id no [AgentRegistry] descriptor claims. Neither can ever be ticked
  /// in the menu, so hiding them would put rows behind a control that cannot
  /// give them back — a session that vanished with no way to ask for it. The
  /// same reasoning `SectionFacts.imported` records for imported history, which
  /// is *not* in that position: an imported conversation names its CLI in
  /// `ImportedSession.cli`, so it is classified and filtered like any other row.
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

/// The agents the filter can name, in registry order.
///
/// The menu is built from the registry rather than from a sweep of the
/// workspace: the registry is three constants and no database statement, and an
/// agent it does not list is one [AgentFilter.allows] never hides anyway.
List<String> filterableAgentIds(AgentRegistry registry) => [
  for (final descriptor in registry.descriptors) descriptor.id,
];

/// What the funnel is doing, said in one sentence.
///
/// **It names both halves.** "Showing Codex only" tells the user what they
/// asked for; naming the agents whose sessions are consequently off the list is
/// what stops a filtered Explorer from reading as a lost session. Names rather
/// than a count, because a workspace-wide count of hidden rows is a sweep of
/// the whole session table and the Explorer only ever reads the projects the
/// user has expanded — see [visibleProjectSessionsProvider], which says the
/// count where it is free to say it.
String agentFilterTooltip(AgentFilter filter, AgentRegistry registry) {
  if (filter.isUnfiltered) return 'Filter sessions';
  final shown = <String>[];
  final hidden = <String>[];
  for (final id in filterableAgentIds(registry)) {
    (filter.agentIds.contains(id) ? shown : hidden).add(
      registry.displayNameFor(id),
    );
  }
  // A filter naming an agent this registry has never heard of — a descriptor
  // removed under a saved choice. Said rather than dropped, so the menu's own
  // ticks and this sentence cannot disagree.
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
