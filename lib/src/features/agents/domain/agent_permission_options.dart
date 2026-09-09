import '../../settings/domain/permission_risk.dart';
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

  /// [label] with the familiar name for its rung in front of it.
  ///
  /// A row is one rung of one CLI, so the pairing belongs here rather than at
  /// the call sites: Settings, the automations form and both menus draw the
  /// same row and must not name it three ways.
  String get pairedLabel => pairedWithFamiliarName(label, value.permits);

  /// The same on a chip's budget.
  String get pairedShortLabel =>
      pairedWithFamiliarName(shortLabel, value.permits);
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

/// [words] with the familiar name for [risk] in front of them, or [words] alone.
///
/// The whole of what was borrowed. Three rules, and each is a decision:
///
/// * A rung with no [PermissionRisk.familiarName] is left exactly as it was,
///   and so is a null [risk] — an agent whose modes are unestablished has no
///   rung to name, and inventing one would be the guess this app refuses
///   everywhere else. Two of the five rungs have none, on purpose — see the
///   field.
/// * A CLI that **already says the word** says it once. Claude Code and
///   Antigravity both label their read-only rung "Plan mode", and "Plan · Plan
///   mode" is not clearer than "Plan mode" — the name is borrowed only where it
///   reads better than ours, which for those two is nowhere.
/// * The CLI's own word never leaves. A person configuring Codex needs
///   `read-only` and `on-request`, so the familiar name is a prefix and never a
///   replacement — and where the CLI's words are already a list (Codex's two
///   axes) they are bracketed, so the reader can tell the one borrowed name
///   from the two the CLI supplied.
String pairedWithFamiliarName(String words, PermissionRisk? risk) {
  final familiar = risk?.familiarName;
  if (familiar == null || words.isEmpty) return words;
  if (words.toLowerCase().contains(familiar.toLowerCase())) return words;
  return words.contains(' · ') ? '$familiar ($words)' : '$familiar · $words';
}

/// [describeSelection] with the familiar name for the selection's rung.
///
/// The rung is [AgentPermissionSupport.riskOf], which composes a multi-axis
/// selection by taking the least any one axis permits — so the name attached
/// here is the one that describes what will actually run, not the loosest axis.
String describeSelectionFamiliar(
  AgentPermissionSupport support,
  PermissionSelection? selection,
) => support.isKnown
    ? pairedWithFamiliarName(
        describeSelection(support, selection),
        support.riskOf(selection),
      )
    : '';

/// The same, in short labels, for a chip with a third of a window to live in.
String describeSelectionFamiliarShort(
  AgentPermissionSupport support,
  PermissionSelection? selection,
) => support.isKnown
    ? pairedWithFamiliarName(
        describeSelectionShort(support, selection),
        support.riskOf(selection),
      )
    : '';

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
