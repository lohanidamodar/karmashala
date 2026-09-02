import 'agent_descriptor.dart';

/// Whether a model can actually be asked for, and if not, why not.
///
/// [PermissionModeFit]'s counterpart, and it exists for the same reason: a row
/// the user cannot choose has to say *which* kind of cannot it is. "This CLI
/// takes no model flag" and "this session is on something my list does not
/// name" are both disabled rows and they mean opposite things.
enum AgentModelFit {
  /// The descriptor names it and the agent can be told. Pick it.
  selectable,

  /// We know what this agent runs and have found no way to ask for one, so it
  /// is shown and not offered — Loop 31 §4's option C, one field over.
  notTellable,

  /// The session is on a model this build's curated list does not name.
  /// Nothing is wrong with it; it simply cannot be recommended.
  unlisted,
}

/// One row of a model control: a model, whether it can be asked for, and the
/// words for saying so.
///
/// Pulled out of the widget for `AgentPermissionOption`'s reason — the
/// *wording* is the feature. A menu that lists a model the CLI will never be
/// told about is the silent no-op with a nicer font.
class AgentModelOption {
  const AgentModelOption({
    required this.model,
    required this.fit,
    required this.agentName,
  });

  final AgentModel model;
  final AgentModelFit fit;

  /// The agent's display name, so every sentence names who is or is not
  /// honouring the choice rather than blaming "the app".
  final String agentName;

  bool get isSelectable => fit == AgentModelFit.selectable;

  /// One sentence about what picking this actually does.
  String get summary => switch (fit) {
    AgentModelFit.selectable => model.summary,
    AgentModelFit.notTellable =>
      '$agentName takes no model flag, so its own default applies and '
          'Karmashala cannot change it.',
    AgentModelFit.unlisted =>
      'Not in Karmashala\'s list for $agentName — set by an older build or by '
          'hand. It is still passed on the next launch; pick one above to '
          'change it.',
  };

  /// A short qualifier for the chip and the menu row, or null when the row is
  /// ordinary. Only the two worth noticing get one.
  String? get fitLabel => switch (fit) {
    AgentModelFit.selectable => null,
    AgentModelFit.notTellable => 'not settable',
    AgentModelFit.unlisted => 'unlisted',
  };
}

/// Every model [descriptor] declares, paired with whether it can be asked for,
/// plus [current] when the session is on something the list does not name.
///
/// A null [descriptor] — the unknown-agent shape — yields an empty list, which
/// is what draws no control at all. That is deliberate: an agent nobody has
/// checked has no models to be wrong about, and a menu of guesses is worse than
/// no menu.
List<AgentModelOption> modelOptionsFor(
  AgentDescriptor? descriptor, {
  String? current,
  String? agentName,
}) {
  final name = agentName ?? descriptor?.displayName ?? 'This agent';
  final support =
      descriptor?.launch.model ?? const AgentModelSupport.unsupported();
  final fit = support.isSupported
      ? AgentModelFit.selectable
      : AgentModelFit.notTellable;
  return [
    for (final model in support.models)
      AgentModelOption(model: model, fit: fit, agentName: name),
    // Last, and only when there is one: the session's own model, when this
    // build's list has never heard of it. Hiding it would leave the chip naming
    // a model that appears nowhere in the menu it opens.
    if (current != null &&
        current.isNotEmpty &&
        support.modelFor(current) == null &&
        support.models.isNotEmpty)
      AgentModelOption(
        model: AgentModel(id: current, label: current, summary: ''),
        fit: AgentModelFit.unlisted,
        agentName: name,
      ),
  ];
}
