import 'agent_descriptor.dart';
import 'agent_permission_support.dart';

/// One row of a permission control: a value the agent really has, and the words
/// for saying what picking it does.
///
/// Pulled out of the widget because the *wording* is the feature — and because
/// two controls draw these (the composer chip and the launcher's picker), and a
/// row that read differently in the two would be two answers to one question.
class AgentPermissionOption {
  const AgentPermissionOption({
    required this.axisId,
    required this.value,
    required this.agentName,
    this.disabledReason,
  });

  final String axisId;
  final AgentPermissionValue value;

  /// The agent's display name, so every sentence names who is or is not
  /// honouring the choice rather than blaming "the app".
  final String agentName;

  /// Why this row cannot be picked, or null when it can.
  ///
  /// The affordance that survived from the shared-enum design: a row the user
  /// cannot choose is **shown, disabled and explained**, never hidden. Hiding
  /// it leaves them wondering where the option went, which is a different kind
  /// of silence. What changed is what puts a row here — a mode the agent cannot
  /// express is no longer possible, because every row *is* one of the agent's
  /// own modes, so the live case is a value another axis has superseded.
  final String? disabledReason;

  bool get isSelectable => disabledReason == null;

  String get id => value.id;
  String get label => value.label;
  String get shortLabel => value.shortLabel;
  bool get isDangerous => value.isDangerous;

  /// One sentence about what picking this actually does to this agent.
  String get summary => disabledReason ?? value.description;
}

/// One axis of one agent, with its rows — what a picker draws.
class AgentPermissionAxisOptions {
  const AgentPermissionAxisOptions({
    required this.id,
    required this.label,
    required this.description,
    required this.options,
    required this.selectedId,
  });

  final String id;
  final String label;
  final String description;

  /// Safest first, in the axis's declared order.
  final List<AgentPermissionOption> options;

  /// The row currently in force on this axis.
  final String selectedId;

  AgentPermissionOption get selected =>
      options.firstWhere((o) => o.id == selectedId, orElse: () => options.first);
}

/// The agent's axes with every row, and the given [selection] marked.
///
/// An agent whose modes have never been established yields an **empty list**,
/// which is what draws the single disabled row saying so — see
/// [unknownAgentReason]. That is deliberate and is the honest shape: a menu of
/// guesses is worse than no menu, and an empty menu with no explanation is
/// worse than both.
List<AgentPermissionAxisOptions> permissionAxisOptionsFor(
  AgentDescriptor? descriptor, {
  PermissionSelection? selection,
  String? agentName,
}) {
  final name = agentName ?? descriptor?.displayName ?? 'This agent';
  final support = descriptor?.launch.permission;
  if (support == null || !support.isKnown) return const [];
  final resolved = support.normalise(selection ?? support.defaultSelection);
  final superseded = support.supersededBy(resolved);
  return [
    for (final axis in support.axes)
      AgentPermissionAxisOptions(
        id: axis.id,
        label: axis.label,
        description: axis.description,
        selectedId: resolved.valueFor(axis.id) ?? axis.defaultValueId,
        options: [
          for (final value in axis.values)
            AgentPermissionOption(
              axisId: axis.id,
              value: value,
              agentName: name,
              disabledReason: superseded.contains(axis.id)
                  ? _supersededReason(support, resolved, axis.id)
                  : null,
            ),
        ],
      ),
  ];
}

/// Why a whole axis is greyed out: something on another axis overrode it.
String? _supersededReason(
  AgentPermissionSupport support,
  PermissionSelection selection,
  String axisId,
) {
  for (final axis in support.axes) {
    final value = axis.valueFor(selection.valueFor(axis.id));
    if (value != null && value.supersedes.contains(axisId)) {
      return '"${value.label}" replaces this, so nothing set here is passed.';
    }
  }
  return null;
}

/// What a control says instead of a menu when the agent's modes are unknown.
///
/// Named rather than inlined so the composer chip, the launcher picker and the
/// phone all say the same thing.
String unknownAgentReason(String agentName) =>
    'Karmashala has not established which permission modes $agentName has, so '
    'it starts under its own default and nothing here can govern it.';

/// The agent's own name for a selection: the chosen values, joined.
///
/// One axis gives "Plan mode"; two give "Read-only · Never ask". Superseded
/// axes are left out, because they contribute nothing to what will run.
String describeSelection(
  AgentPermissionSupport support,
  PermissionSelection? selection,
) {
  if (!support.isKnown) return '';
  final resolved = support.normalise(selection);
  final superseded = support.supersededBy(resolved);
  return [
    for (final axis in support.axes)
      if (!superseded.contains(axis.id))
        axis.valueFor(resolved.valueFor(axis.id))?.label,
  ].whereType<String>().join(' · ');
}

/// The same, in short labels, for a chip with a third of a window to live in.
String describeSelectionShort(
  AgentPermissionSupport support,
  PermissionSelection? selection,
) {
  if (!support.isKnown) return '';
  final resolved = support.normalise(selection);
  final superseded = support.supersededBy(resolved);
  return [
    for (final axis in support.axes)
      if (!superseded.contains(axis.id))
        axis.valueFor(resolved.valueFor(axis.id))?.shortLabel,
  ].whereType<String>().join(' · ');
}

/// What the chosen values say they do, joined into one sentence.
String? describeSelectionDetail(
  AgentPermissionSupport support,
  PermissionSelection? selection,
) {
  if (!support.isKnown) return null;
  final resolved = support.normalise(selection);
  final superseded = support.supersededBy(resolved);
  final parts = [
    for (final axis in support.axes)
      if (!superseded.contains(axis.id))
        axis.valueFor(resolved.valueFor(axis.id))?.description,
  ].whereType<String>().toList();
  return parts.isEmpty ? null : parts.join(' ');
}
