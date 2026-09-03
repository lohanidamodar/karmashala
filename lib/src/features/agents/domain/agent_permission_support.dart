import '../../settings/domain/permission_risk.dart';

/// One value of one permission axis — a mode the CLI actually has, in the
/// CLI's own words.
class AgentPermissionValue {
  const AgentPermissionValue({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.description,
    required this.arguments,
    required this.permits,
    required this.evidence,
    this.isDangerous = false,
    this.supersedes = const [],
  });

  /// Stable and persisted. The CLI's own token wherever it has one.
  final String id;

  final String label;

  /// The name that fits on a chip.
  final String shortLabel;

  /// What this does, quoted from the CLI wherever it says so itself.
  final String description;

  /// What goes on the command line. May be empty for a value that *is* the
  /// CLI's unflagged behaviour — see the note that must accompany one.
  final List<String> arguments;

  /// The most this value permits. An axis is a **cap**, so a selection across
  /// several axes permits the least any one of them does.
  final PermissionRisk permits;

  /// Where this was read off — the `--help` line, the rejection message or the
  /// binary string — so a future CLI version can be re-checked.
  final String evidence;

  /// Warned about and confirmed before it is applied.
  final bool isDangerous;

  /// Axis ids this value overrides. Codex's
  /// `--dangerously-bypass-approvals-and-sandbox` supersedes the approval axis:
  /// choosing it disables that picker and contributes none of its arguments.
  final List<String> supersedes;
}

/// One dimension of an agent's permission policy.
///
/// Most agents have exactly one. Codex has two — a *sandbox* deciding what may
/// be written and an *approval policy* deciding what must be asked — and the
/// request that produced this model was explicitly that they not be squeezed
/// back into one picker.
class AgentPermissionAxis {
  const AgentPermissionAxis({
    required this.id,
    required this.label,
    required this.description,
    required this.defaultValueId,
    required this.values,
  });

  final String id;
  final String label;
  final String description;

  /// The value a session that has chosen nothing runs under. Must name a value
  /// that is not [AgentPermissionValue.isDangerous] — asserted in the tests,
  /// because a dangerous default is architecture constraint 12's whole subject.
  final String defaultValueId;

  /// Safest first. That order is the axis's contribution to the safety order,
  /// and the pickers render it unchanged.
  final List<AgentPermissionValue> values;

  AgentPermissionValue? valueFor(String? id) {
    if (id == null) return null;
    for (final value in values) {
      if (value.id == id) return value;
    }
    return null;
  }

  AgentPermissionValue get defaultValue =>
      valueFor(defaultValueId) ?? values.first;
}

/// One value per axis: what a session is actually set to.
///
/// A single-axis agent's selection is a map of one entry, which is exactly the
/// shape a two-axis agent's is — so nothing downstream special-cases the
/// difference.
class PermissionSelection {
  const PermissionSelection(this.values);

  /// The empty selection: nothing chosen, for an agent whose modes have never
  /// been established. Contributes no arguments and claims nothing.
  static const empty = PermissionSelection({});

  /// Axis id to value id.
  final Map<String, String> values;

  bool get isEmpty => values.isEmpty;

  String? valueFor(String axisId) => values[axisId];

  /// `sandbox=workspace-write;approval=on-request` — what the session row and
  /// the settings file hold, and what crosses the wire to the phone.
  ///
  /// Sorted by axis id rather than by declaration order so the string is stable
  /// even if an axis is later reordered on the descriptor.
  String get canonical {
    final keys = values.keys.toList()..sort();
    return [for (final key in keys) '$key=${values[key]}'].join(';');
  }

  /// Reads [canonical] back. Returns `null` for null, empty or malformed input
  /// — never a fabricated selection.
  static PermissionSelection? parse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = <String, String>{};
    for (final pair in trimmed.split(';')) {
      final split = pair.indexOf('=');
      if (split <= 0 || split == pair.length - 1) return null;
      parsed[pair.substring(0, split)] = pair.substring(split + 1);
    }
    return parsed.isEmpty ? null : PermissionSelection(parsed);
  }

  @override
  bool operator ==(Object other) =>
      other is PermissionSelection && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => canonical.isEmpty ? 'PermissionSelection()' : canonical;
}

/// The permission vocabulary of one agent CLI.
///
/// Declared data on the descriptor, [evidence] required, defaulting to the
/// conservative answer — the same contract `AgentModelSupport`,
/// `AgentForkSupport` and `AgentResumeLocality` hold their claims to. Nothing
/// anywhere branches on an agent's *name* to decide what modes it has.
class AgentPermissionSupport {
  /// The agent's own modes, one axis or several.
  const AgentPermissionSupport.axes({
    required this.axes,
    required this.evidence,
  });

  /// Nobody has established this agent's modes. **The default**, and what a
  /// registry-only agent gets: no mode is offered, the picker says so in one
  /// disabled row, and the launch passes no permission flags rather than
  /// claiming a policy we have not seen.
  const AgentPermissionSupport.unknown() : axes = const [], evidence = '';

  final List<AgentPermissionAxis> axes;

  /// The CLI version and command output the whole vocabulary was read off.
  final String evidence;

  bool get isKnown => axes.isNotEmpty;

  AgentPermissionAxis? axisFor(String id) {
    for (final axis in axes) {
      if (axis.id == id) return axis;
    }
    return null;
  }

  /// The selection a session that has chosen nothing runs under.
  PermissionSelection get defaultSelection => PermissionSelection({
    for (final axis in axes) axis.id: axis.defaultValueId,
  });

  /// Which axes [selection] leaves with nothing to say, because a chosen value
  /// supersedes them.
  Set<String> supersededBy(PermissionSelection selection) => {
    for (final axis in axes)
      ...?axis.valueFor(selection.valueFor(axis.id))?.supersedes,
  };

  /// [selection] with every axis filled in, unknown values replaced by the
  /// axis default, and superseded axes reset to their default so two selections
  /// that mean the same thing compare equal.
  PermissionSelection normalise(PermissionSelection? selection) {
    if (!isKnown) return PermissionSelection.empty;
    final chosen = <String, String>{
      for (final axis in axes)
        axis.id:
            axis.valueFor(selection?.valueFor(axis.id))?.id ??
            axis.defaultValue.id,
    };
    final superseded = supersededBy(PermissionSelection(chosen));
    for (final axis in axes) {
      if (superseded.contains(axis.id)) chosen[axis.id] = axis.defaultValue.id;
    }
    return PermissionSelection(chosen);
  }

  /// The command line for [selection], in axis order, skipping superseded axes.
  List<String> argumentsFor(PermissionSelection? selection) {
    if (!isKnown) return const [];
    final resolved = normalise(selection);
    final superseded = supersededBy(resolved);
    return [
      for (final axis in axes)
        if (!superseded.contains(axis.id))
          ...?axis.valueFor(resolved.valueFor(axis.id))?.arguments,
    ];
  }

  /// How permissive [selection] is: the **least** any of its axes permits.
  ///
  /// `min`, not `max`, because every axis is a restriction. Codex's
  /// `--sandbox read-only --ask-for-approval never` cannot write whatever the
  /// approval policy says, and `--sandbox danger-full-access
  /// --ask-for-approval untrusted` asks before anything whatever the sandbox
  /// allows. Taking the maximum would over-state the first and the minimum is
  /// what actually composes.
  ///
  /// `null` for an agent with no declared modes: there is nothing to measure,
  /// and [PermissionRisk.ask] would be a guess about an unverified default.
  PermissionRisk? riskOf(PermissionSelection? selection) {
    if (!isKnown) return null;
    final resolved = normalise(selection);
    final superseded = supersededBy(resolved);
    PermissionRisk? risk;
    for (final axis in axes) {
      if (superseded.contains(axis.id)) continue;
      final value = axis.valueFor(resolved.valueFor(axis.id));
      if (value == null) continue;
      risk = risk == null ? value.permits : risk.lesser(value.permits);
    }
    return risk;
  }

  /// Whether [selection] is one the user must confirm before it is applied.
  ///
  /// Two ways to be: a value that says so itself, or a **combination** that
  /// adds up to [PermissionRisk.bypass] without any single value being
  /// alarming. Codex's `--sandbox danger-full-access --ask-for-approval never`
  /// is the second — two ordinary-looking picks that between them leave
  /// nothing at all in the way.
  bool isDangerous(PermissionSelection? selection) {
    if (!isKnown) return false;
    if (riskOf(selection) == PermissionRisk.bypass) return true;
    final resolved = normalise(selection);
    final superseded = supersededBy(resolved);
    for (final axis in axes) {
      if (superseded.contains(axis.id)) continue;
      if (axis.valueFor(resolved.valueFor(axis.id))?.isDangerous ?? false) {
        return true;
      }
    }
    return false;
  }

  /// Every distinct selection this agent has, safest first.
  ///
  /// The cross product, with superseded axes collapsed to one row — 7 for
  /// Codex's 4x2, not 8 — and de-duplicated by [PermissionSelection.canonical].
  /// Enumerated rather than declared because the pickers never show this: it is
  /// what the handoff carry rule and the phone's flat option list read, and at
  /// these sizes enumerating is cheaper than a second declaration that could
  /// disagree with the first.
  List<PermissionSelection> selections() {
    if (!isKnown) return const [];
    var rows = <Map<String, String>>[{}];
    for (final axis in axes) {
      rows = [
        for (final row in rows)
          for (final value in axis.values) {...row, axis.id: value.id},
      ];
    }
    final seen = <String>{};
    final out = <PermissionSelection>[];
    for (final row in rows) {
      final selection = normalise(PermissionSelection(row));
      if (!seen.add(selection.canonical)) continue;
      out.add(selection);
    }
    out.sort((a, b) {
      final left = riskOf(a)?.index ?? 0;
      final right = riskOf(b)?.index ?? 0;
      if (left != right) return left.compareTo(right);
      return a.canonical.compareTo(b.canonical);
    });
    return out;
  }

  /// The axes of [selection] whose stored value this build does not name.
  ///
  /// [normalise] substitutes the axis default for one, which is the only thing
  /// it can do — there are no arguments to pass for a value we have never heard
  /// of. Substituting *silently* would be the lie this file exists to remove,
  /// so the fact is exposed and the controls say it.
  List<String> unknownAxes(PermissionSelection? selection) {
    if (!isKnown || selection == null) return const [];
    return [
      for (final axis in axes)
        if (selection.valueFor(axis.id) != null &&
            axis.valueFor(selection.valueFor(axis.id)) == null)
          axis.id,
    ];
  }
}
