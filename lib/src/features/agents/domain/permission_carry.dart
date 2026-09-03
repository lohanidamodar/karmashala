import '../../settings/domain/permission_risk.dart';
import 'agent_descriptor.dart';
import 'agent_permission_options.dart';
import 'agent_permission_support.dart';

/// What happens to a session's permission when the work moves to a different
/// agent.
///
/// A handoff crosses the one boundary the per-agent model cannot remove: the
/// mode was chosen in **one CLI's vocabulary**, and the agent receiving it does
/// not speak that vocabulary at all. `mode=acceptEdits` means nothing to Codex.
/// So the two are compared on the only thing they share — [PermissionRisk], how
/// permissive the mode is — and the target is given the closest thing it really
/// has.
///
/// The rule: **carry it if the target reaches that rung, otherwise fall
/// downwards, and never upwards.**
class CarriedPermission {
  const CarriedPermission({
    required this.requested,
    required this.selection,
    required this.risk,
    required this.fit,
    required this.targetAgentName,
    this.label = '',
    this.note,
  });

  /// How permissive the source session is.
  final PermissionRisk requested;

  /// What the target will actually be launched with, in its own vocabulary.
  /// Empty for an agent with no declared modes.
  final PermissionSelection selection;

  /// How permissive [selection] actually is, or null when the target declares
  /// nothing and there is therefore nothing to measure.
  final PermissionRisk? risk;

  /// How faithfully the rung survived the move.
  final PermissionModeFit fit;

  final String targetAgentName;

  /// The target's own name for [selection] — "Plan mode", "Read-only ·
  /// Never ask".
  final String label;

  /// The target's own words about what it will do.
  final String? note;

  /// Whether the rung had to change to survive the move.
  bool get changed => risk != null && risk != requested;

  /// Whether the target can be told anything at all about this.
  bool get enforced => fit != PermissionModeFit.none;

  /// One sentence for the confirmation step, so the user reads what will
  /// happen **before** anything is launched rather than discovering it after.
  ///
  /// Every branch names the agent. "Karmashala cannot enforce this" invites the
  /// reader to blame the app for a limit that belongs to the CLI, and the
  /// user's next decision — go ahead, or pick a different agent — depends on
  /// knowing which.
  String get summary {
    if (!enforced) {
      return '$targetAgentName takes no mode as careful as '
          '${requested.label.toLowerCase()}, and nothing safer that it does '
          'understand, so it will start under its own default and Karmashala '
          'cannot govern it.';
    }
    if (!changed) return '$label — $targetAgentName is told to use it.';
    return '${requested.label} is not something $targetAgentName can be put '
        'into, so it starts under the closest mode it does have, which is no '
        'more permissive than what you asked for: $label.'
        '${note == null ? '' : ' $note'}';
  }
}

/// Resolves [requested] against [target].
///
/// 1. The **most permissive** selection the target has whose rung is no more
///    permissive than [requested]. Equal rung is an [PermissionModeFit.exact]
///    carry; anything lower is [PermissionModeFit.approximate] and says so.
/// 2. If the target has nothing at or below [requested] — every mode it owns is
///    *more* permissive — **nothing is passed** and the agent's own default
///    applies, reported as [PermissionModeFit.none] and said out loud. Handing
///    over even the target's safest mode would still exceed what the user
///    asked for.
/// 3. A target with no declared modes likewise carries nothing and says so.
///
/// The downwards-only clause in step 1 is the whole safety property, and
/// Antigravity is why it is written this way rather than as "the nearest mode":
/// a rule that reached for the nearest available rung could answer a handoff of
/// a careful ask-every-time session by launching the next agent in a bypass —
/// turning the user's safest choice into the most dangerous one as a side
/// effect of changing provider.
CarriedPermission carryPermission(
  PermissionRisk requested,
  AgentDescriptor? target, {
  String? targetName,
}) {
  final name = targetName ?? target?.displayName ?? 'This agent';
  final support = target?.launch.permission;
  if (support == null || !support.isKnown) {
    return CarriedPermission(
      requested: requested,
      selection: PermissionSelection.empty,
      risk: null,
      fit: PermissionModeFit.none,
      targetAgentName: name,
    );
  }

  // Safest-first, so the last one at or below the ceiling is the most
  // permissive the target can be given without exceeding what was asked for.
  final selections = support.selections();
  PermissionSelection? best;
  for (final candidate in selections) {
    final risk = support.riskOf(candidate);
    if (risk != null && risk.isAtMost(requested)) best = candidate;
  }

  if (best == null) {
    // Everything this agent has is **more permissive** than what was asked
    // for, so nothing is passed and the agent's own default applies.
    //
    // This is the one place the per-agent model deliberately does pass no
    // flag, and it is the lesser of two evils rather than an oversight.
    // Handing over the agent's *safest* mode would still be more permissive
    // than the user asked for — for an agent whose only mode is a bypass, it
    // would answer the handoff of a careful session by launching the next
    // agent with nothing in the way. Turning the user's safest choice into
    // the most dangerous one as a side effect of changing provider is the
    // exact failure this rule exists to prevent, so the honest answer is to
    // enforce nothing and say so.
    return CarriedPermission(
      requested: requested,
      selection: PermissionSelection.empty,
      risk: null,
      fit: PermissionModeFit.none,
      targetAgentName: name,
    );
  }

  final risk = support.riskOf(best);
  return CarriedPermission(
    requested: requested,
    selection: best,
    risk: risk,
    fit: risk == requested
        ? PermissionModeFit.exact
        : PermissionModeFit.approximate,
    targetAgentName: name,
    label: describeSelection(support, best),
    note: describeSelectionDetail(support, best),
  );
}

/// Where the mode a continuation launches under came from.
enum PermissionChoiceOrigin {
  /// Nobody picked one: the source session's rung, put through
  /// [carryPermission].
  carried,

  /// The user picked it, for the agent they had chosen at the time.
  chosen,
}

/// The permission decision for one continuation target: the modes that agent
/// can be put into, the one it will launch under, and where that came from.
///
/// One value rather than a selection sitting beside a list in the dialog's
/// state, because all of it changes together the moment the user picks a
/// different agent — a selection that outlived the agent it was made for is
/// exactly the bug this shape makes unrepresentable.
class ContinuationPermission {
  const ContinuationPermission({
    required this.carried,
    required this.axes,
    required this.origin,
  });

  /// How the selected mode reaches the target.
  final CarriedPermission carried;

  /// The target's own axes, each with its rows — what a picker draws. Empty for
  /// an agent whose modes have never been established, which draws the single
  /// disabled row that says so.
  final List<AgentPermissionAxisOptions> axes;

  final PermissionChoiceOrigin origin;

  /// The selection the launch will request.
  PermissionSelection get selection => carried.selection;

  bool get wasChosen => origin == PermissionChoiceOrigin.chosen;

  /// The line under the picker: where this mode came from, and what it does to
  /// this agent.
  ///
  /// Only the default needs its origin stated. A mode the user picked is not a
  /// surprise to them; the default is one they never made.
  String get explanation => switch (origin) {
    PermissionChoiceOrigin.chosen => carried.summary,
    PermissionChoiceOrigin.carried =>
      'Carried from this session. ${carried.summary}',
  };
}

/// What continuing a session that runs at [sessionRisk] in [target] will launch
/// under, given whatever the user picked for that agent.
///
/// [chosen] is a selection in the **target's** vocabulary — the user picked it
/// from the target's own axes, so it needs no carrying and is used as-is. The
/// carry rule only applies when nobody has picked, which is the case it exists
/// for: moving a decision made for one CLI onto another.
ContinuationPermission resolveContinuationPermission({
  required PermissionRisk sessionRisk,
  required AgentDescriptor? target,
  PermissionSelection? chosen,
  String? targetName,
}) {
  final name = targetName ?? target?.displayName ?? 'This agent';
  final support = target?.launch.permission;
  final carried = chosen == null || support == null || !support.isKnown
      ? carryPermission(sessionRisk, target, targetName: name)
      : CarriedPermission(
          requested: sessionRisk,
          selection: support.normalise(chosen),
          risk: support.riskOf(chosen),
          fit: PermissionModeFit.exact,
          targetAgentName: name,
          label: describeSelection(support, chosen),
          note: describeSelectionDetail(support, chosen),
        );
  return ContinuationPermission(
    carried: carried,
    axes: permissionAxisOptionsFor(target, agentName: name),
    origin: chosen == null
        ? PermissionChoiceOrigin.carried
        : PermissionChoiceOrigin.chosen,
  );
}

/// The most a session started to **review** someone else's work may be trusted
/// with.
///
/// [PermissionRisk.ask] is not a conservative preference here, it is the cap
/// that follows from "a reviewer must not write": every rung above it
/// auto-approves edits, and a review that fixed the thing it graded is not
/// evidence of anything.
///
/// **[PermissionRisk.readOnly] is expressible, and it was measured, and it is
/// not the better cap.** Claude Code 2.1.259 was asked directly, because the
/// hoped-for property was that plan mode separates *running* a command from
/// *writing* a file:
///
/// * `claude -p --permission-mode plan` ran `cat a.txt` with no prompt. In
///   print mode an "ask" is a refusal, so that is a real allow.
/// * The same run under `--permission-mode manual` allowed the same command,
///   and both modes refused `touch` identically, with the same
///   working-directory message. Plan is not the reason either way.
/// * Asked to run a test script, plan answered *"blocked by the current
///   session (This command requires approval)"* and manual answered *"requires
///   your approval"*. The same answer in the same words.
/// * In the 2.1.259 binary, **every** plan-mode permission decision is
///   `behavior:"ask"` — file writes, memory saves, SendFile and non-read-only
///   MCP tools — and none of the four is Bash. Plan mode never denies, and it
///   holds no Bash gate at all. Its "no non-readonly tools" is a line in the
///   system reminder: *"Plan mode is active… you MUST NOT make any edits, run
///   any non-readonly tools… or otherwise make any changes to the system."*
///
/// So plan mode is not "read and run, never write"; at the enforcement layer it
/// is [PermissionRisk.ask] with a prompt asking the model to behave, plus a
/// workflow that ends in a plan for approval. Lowering the ceiling would buy no
/// enforcement and would swap a reviewer for a planner — and, through the
/// carry rule's "most permissive at or below", it would select `mode=plan` on
/// Claude Code and `mode=plan` on Antigravity, not the `dontAsk` rung, whose
/// auto-deny is the "reviewer that cannot run what it needs" failure outright.
/// The gap this comment used to name is real; this rung does not close it.
const PermissionRisk reviewPermissionCeiling = PermissionRisk.ask;

/// What a review session will actually launch under, and whether the session it
/// reviews was more autonomous than that.
class ReviewCarry {
  const ReviewCarry({required this.carried, required this.sessionRisk});

  /// The ordinary carry, run against the ceiling rather than against the
  /// reviewed session's own rung.
  final CarriedPermission carried;

  /// How permissive the session under review is. Recorded so the cap can say
  /// what it reduced, which is the only part of this a user cannot see
  /// elsewhere.
  final PermissionRisk sessionRisk;

  /// The selection the review will be launched with.
  PermissionSelection get selection => carried.selection;

  /// Whether the reviewed session runs under something the ceiling refused to
  /// carry across.
  bool get wasCapped => !sessionRisk.isAtMost(reviewPermissionCeiling);

  /// One sentence for the control that starts the review.
  String get summary {
    final cap = wasCapped
        ? 'That session runs at ${sessionRisk.label.toLowerCase()}; a review is '
              'capped at ${reviewPermissionCeiling.label.toLowerCase()}, '
              'because an agent that may write is not reviewing the change, it '
              'is changing it. '
        : 'A review may read and run, never write. ';
    return '$cap${carried.summary}';
  }
}

/// The permission a review of a session at [sessionRisk] gets in [target].
///
/// Two rules compose here and the order matters. The ceiling is applied
/// **first**, to the request, so what reaches [carryPermission] is already no
/// more than a reviewer may have; [carryPermission] then applies its own
/// downwards-only rule to fit that onto the agent.
ReviewCarry carryReviewPermission({
  required PermissionRisk sessionRisk,
  required AgentDescriptor? target,
  String? targetName,
}) {
  final requested = sessionRisk.isAtMost(reviewPermissionCeiling)
      ? sessionRisk
      : reviewPermissionCeiling;
  return ReviewCarry(
    carried: carryPermission(requested, target, targetName: targetName),
    sessionRisk: sessionRisk,
  );
}
