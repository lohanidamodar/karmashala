import '../../settings/domain/permission_mode.dart';
import 'agent_descriptor.dart';
import 'agent_permission_options.dart';

/// What happens to a session's permission mode when the work moves to a
/// different agent.
///
/// A handoff crosses a boundary Loop 49 never had to: the mode was resolved for
/// **one** agent, and the agent receiving it may not have that mode at all.
/// Loop 49's answer for a single agent was option C — do not offer what cannot
/// happen — but that answer is not available here, because the user is not
/// picking a mode, they are picking an *agent*, and the mode has to go
/// somewhere.
///
/// So the rule is: **carry it if it maps, otherwise fall back downwards, and
/// never silently upwards.**
class CarriedPermission {
  const CarriedPermission({
    required this.requested,
    required this.mode,
    required this.fit,
    required this.targetAgentName,
    this.note,
  });

  /// The mode the source session runs under.
  final PermissionMode requested;

  /// The mode the target will actually be launched with.
  final PermissionMode mode;

  /// How faithfully [mode] reaches the target agent.
  final PermissionModeFit fit;

  final String targetAgentName;

  /// The target descriptor's own words about [mode], when it has any.
  final String? note;

  /// Whether the mode had to change to survive the move.
  bool get changed => mode != requested;

  /// Whether the target can be told anything at all about this.
  bool get enforced => fit != PermissionModeFit.none;

  /// One sentence for the confirmation step, so the user reads what will
  /// happen **before** anything is launched rather than discovering it after.
  ///
  /// Every branch names the agent. "Chitragupta cannot enforce this" invites
  /// the reader to blame the app for a limit that belongs to the CLI, and the
  /// user's next decision — go ahead, or pick a different agent — depends on
  /// knowing which.
  String get summary {
    if (!enforced) {
      return '$targetAgentName takes no flag for ${requested.label.toLowerCase()} '
          'and nothing safer that it does understand, so it will start under '
          'its own default and Chitragupta cannot govern it.';
    }
    final about = switch (fit) {
      PermissionModeFit.exact => '$targetAgentName is told to use it.',
      PermissionModeFit.approximate =>
        'Approximate for $targetAgentName. ${note ?? ''}'.trim(),
      PermissionModeFit.none => '',
    };
    if (!changed) return '${mode.label} — $about';
    return '${requested.label} is not something $targetAgentName can be put '
        'into, so it starts under the safest mode it does express, which is '
        'no more permissive than what you asked for: ${mode.label}. $about';
  }
}

/// Resolves [requested] against [target].
///
/// 1. If the target expresses [requested], carry it unchanged — exactly or
///    approximately, and say which.
/// 2. Otherwise take the **safest** mode the target does express, and only if
///    it is no more permissive than [requested]. `PermissionMode.values` is
///    ordered safest-first, which is what makes "no more permissive" an index
///    comparison rather than a table.
/// 3. Otherwise carry [requested] with [PermissionModeFit.none] and say the
///    agent's own default applies.
///
/// Step 2's *downwards only* clause is the whole safety property, and
/// Antigravity is exactly why it is written this way rather than as "the
/// nearest mode": its only expressible mode is `bypass`. A rule that reached
/// for the nearest available mode would answer a handoff of a careful `ask`
/// session by launching the next agent with `--yolo` — turning the user's
/// safest choice into the most dangerous one as a side effect of changing
/// provider. Under this rule that case falls to step 3, which passes no flag
/// and says so.
CarriedPermission carryPermission(
  PermissionMode requested,
  AgentDescriptor? target, {
  String? targetName,
}) {
  final name = targetName ?? target?.displayName ?? 'This agent';
  final launch = target?.launch;
  final fit = launch?.permissionFitFor(requested) ?? PermissionModeFit.none;
  if (fit != PermissionModeFit.none) {
    return CarriedPermission(
      requested: requested,
      mode: requested,
      fit: fit,
      targetAgentName: name,
      note: launch?.permissionNoteFor(requested),
    );
  }

  final ceiling = PermissionMode.values.indexOf(requested);
  for (final candidate in PermissionMode.values) {
    if (PermissionMode.values.indexOf(candidate) > ceiling) break;
    final candidateFit =
        launch?.permissionFitFor(candidate) ?? PermissionModeFit.none;
    if (candidateFit == PermissionModeFit.none) continue;
    return CarriedPermission(
      requested: requested,
      mode: candidate,
      fit: candidateFit,
      targetAgentName: name,
      note: launch?.permissionNoteFor(candidate),
    );
  }

  return CarriedPermission(
    requested: requested,
    mode: requested,
    fit: PermissionModeFit.none,
    targetAgentName: name,
  );
}

/// Where the mode a continuation launches under came from.
enum PermissionChoiceOrigin {
  /// Nobody picked one: the source session's mode, put through
  /// [carryPermission].
  carried,

  /// The user picked it, for the agent they had chosen at the time.
  chosen,
}

/// The permission decision for one continuation target: the modes that agent
/// can be put into, the one it will launch under, and where that came from.
///
/// One value rather than a mode sitting beside a list in the dialog's state,
/// because all three answers change together the moment the user picks a
/// different agent — a selection that outlived the agent it was made for is
/// exactly the bug this shape makes unrepresentable.
class ContinuationPermission {
  const ContinuationPermission({
    required this.carried,
    required this.options,
    required this.origin,
  });

  /// How the selected mode reaches the target: the same [carryPermission]
  /// answer the target row shows, re-run against whatever the user picked.
  final CarriedPermission carried;

  /// Every mode with how it maps onto this agent, safest first. A mode the
  /// descriptor cannot express is present and **not selectable** — a picker
  /// changes nothing about Loop 31 §4 option C.
  final List<AgentPermissionOption> options;

  final PermissionChoiceOrigin origin;

  /// The mode the launch will request.
  PermissionMode get mode => carried.mode;

  bool get wasChosen => origin == PermissionChoiceOrigin.chosen;

  /// The selected mode's own row, so a control renders the selection through
  /// the same option the menu offers rather than a second description of it.
  AgentPermissionOption get selected =>
      options.firstWhere((option) => option.mode == mode);

  /// The line under the picker: where this mode came from, and what it does to
  /// this agent.
  ///
  /// Only the default needs its origin stated. A mode the user picked is not a
  /// surprise to them; the default is one they never made, so it says so —
  /// including when the carry rule had to change it, which
  /// [CarriedPermission.summary] already explains in the agent's own terms.
  String get explanation => switch (origin) {
    PermissionChoiceOrigin.chosen => carried.summary,
    PermissionChoiceOrigin.carried =>
      'Carried from this session. ${carried.summary}',
  };
}

/// What continuing a session that runs under [sessionMode] in [target] will
/// launch under, given whatever the user picked for that agent.
///
/// [chosen] does not step around [carryPermission], it **replaces its input**.
/// A pick is a request like any other and gets the same downwards-only
/// treatment, so offering a picker cannot become a way around the one rule
/// this file exists for. It is also what makes changing the agent safe: a mode
/// picked while one agent was selected falls to the safest thing the next agent
/// does express, rather than staying selected and being silently dropped at
/// launch.
ContinuationPermission resolveContinuationPermission({
  required PermissionMode sessionMode,
  required AgentDescriptor? target,
  PermissionMode? chosen,
  String? targetName,
}) {
  final name = targetName ?? target?.displayName ?? 'This agent';
  return ContinuationPermission(
    carried: carryPermission(chosen ?? sessionMode, target, targetName: name),
    options: permissionOptionsFor(target, agentName: name),
    origin: chosen == null
        ? PermissionChoiceOrigin.carried
        : PermissionChoiceOrigin.chosen,
  );
}
