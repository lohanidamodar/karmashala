/// The rules that decide whether an agent may be started with nobody watching.
///
/// **Pure, and over plain inputs.** Nothing here reads a table, a setting or a
/// filesystem; the lookups live in `unattended_preflight.dart` and hand the
/// answers in. That split is what makes one gate serve every unattended entry
/// point — arming in the UI, a scheduled fire, the queue drain — so an
/// automation cannot be refused by one path and armed by another, and what the
/// arm form says on hover is the sentence the write path throws.
library;

import '../../settings/domain/permission_risk.dart';

/// Where the agent would run, as the environment resolver answered.
///
/// Three values because they are three different things to tell a person: the
/// checkout names an environment this app can run a command in; nothing names
/// where its commands would run at all; or it is named and unreachable from
/// here. `EnvironmentRefusal.sshUnavailable` is exactly the third — *this app
/// cannot reach where the agent would run* — and it maps here rather than
/// being re-derived, so the resolver stays the one answer to that question.
enum UnattendedReach {
  /// Named, and a command can be run there from this app.
  reachable,

  /// Nothing says where this checkout's commands would run.
  unnamed,

  /// Named, and this app cannot reach it.
  unreachable,
}

/// Why an automation may not fire with nobody watching.
///
/// Named values rather than a bare string so a surface can decide *where* to
/// send the user — the verification rules point at the checkout's checks, the
/// permission rule at the agent's own modes — while the sentence stays the
/// same wherever it is shown.
enum UnattendedRefusalKind {
  /// Verification is off for the checkout the automation would run in.
  verificationDisabled,

  /// Verification is on and there is nothing configured for it to run.
  noProjectChecks,

  /// The agent this was armed on is no longer installed here.
  agentUnavailable,

  /// Nobody has established which permission modes this agent has.
  permissionModeUnknown,

  /// The chosen mode stops and asks, and no one would be there to answer.
  permissionModeCanPrompt,

  /// Nothing says where the agent would run.
  environmentUnnamed,

  /// It is named, and this app cannot reach it.
  environmentUnreachable,
}

/// One refusal: what rule said no, in the words a person reads.
///
/// There is exactly one refusal type on purpose. The arm form shows [reason],
/// the write path throws [reason], and the recorded `missed`/`failed` run row
/// stores [reason] — so a reason on hover is the reason arming would throw.
class UnattendedRefusal {
  const UnattendedRefusal(this.kind, this.reason);

  final UnattendedRefusalKind kind;

  /// One or two sentences, fit to show and to throw with. Never empty.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is UnattendedRefusal && other.kind == kind && other.reason == reason;

  @override
  int get hashCode => Object.hash(kind, reason);

  @override
  String toString() => reason;
}

/// Everything the rules read, already looked up.
class UnattendedGateInput {
  const UnattendedGateInput({
    required this.repositoryName,
    required this.verificationEnabled,
    required this.projectCheckCount,
    required this.agentName,
    required this.permits,
    required this.reach,
    this.agentInstalled = true,
    this.permissionLabel = '',
    this.permissionEvidence = '',
    this.reachReason = '',
  });

  /// The checkout's own name, so a sentence names the thing that is not ready.
  final String repositoryName;

  /// Whether this checkout's work is verified at all.
  final bool verificationEnabled;

  /// How many project checks the checkout has configured.
  final int projectCheckCount;

  final String agentName;

  /// Whether the installation this was armed on is still here.
  ///
  /// An arming-time precondition that lapses on its own: the CLI is
  /// uninstalled, or its row went away. Refused rather than resolved to
  /// another installation — an automation names *this* agent on *this*
  /// machine, and silently running it somewhere else is the substitution the
  /// whole gate exists to prevent.
  final bool agentInstalled;

  /// The most the chosen permission selection permits, or **null when nobody
  /// has established this agent's modes** — `AgentPermissionSupport.riskOf`
  /// answers null for an unknown agent and for "enforce nothing", and both are
  /// the absence of a claim rather than a permissive one.
  final PermissionRisk? permits;

  /// The mode's own label, for the sentence. Empty when there is none.
  final String permissionLabel;

  /// The CLI output the mode was read off, quoted so a refusal can be checked.
  final String permissionEvidence;

  final UnattendedReach reach;

  /// The resolver's own sentence, carried through rather than restated so the
  /// two cannot drift.
  final String reachReason;
}

/// Whether a mode still stops and asks a human.
///
/// Decided on the rung, because the rung is the part that carries evidence:
/// every [PermissionRisk] value's own description says what it does, and two
/// of them say they ask. [PermissionRisk.ask] is *"Prompts before edits and
/// commands"*; [PermissionRisk.acceptEdits] is *"Writes without asking. Still
/// asks before running commands"* — so an automation armed on either would
/// stop at a prompt with nobody in the room, which is a button that silently
/// does nothing.
///
/// The other three do not ask. [PermissionRisk.readOnly] changes nothing, so
/// there is nothing to ask permission for; [PermissionRisk.autoRun] says *"no
/// routine prompts"*; [PermissionRisk.bypass] says *"no prompts"*. Bypass is
/// **not** refused here — it is [PermissionRisk.isDangerous], which the arm
/// form warns about and makes the person confirm, and inventing a second
/// refusal for it would be this gate deciding a question the arming human
/// already answered.
///
/// A null rung is not an answer and is handled by [unattendedRefusal] rather
/// than by this function: "we have not established what this does" is refused,
/// never read as "it does not prompt" (§19).
bool permissionModeCanPrompt(PermissionRisk risk) =>
    risk == PermissionRisk.ask || risk == PermissionRisk.acceptEdits;

/// Why this automation may not fire unattended, or `null` when it may.
///
/// The order is the order a person can act in: what the checkout is missing
/// first, then the mode they picked, then whether we can get to the machine at
/// all — because fixing the last one is not something the arm form can offer.
UnattendedRefusal? unattendedRefusal(UnattendedGateInput input) {
  final repository = input.repositoryName.trim().isEmpty
      ? 'this checkout'
      : input.repositoryName.trim();
  final agent = input.agentName.trim().isEmpty
      ? 'this agent'
      : input.agentName.trim();

  if (!input.verificationEnabled) {
    return UnattendedRefusal(
      UnattendedRefusalKind.verificationDisabled,
      'Verification is off for $repository. Nobody is watching an automation '
      'run, so what it did has to be checkable without you — turn verification '
      'on for this checkout and give it at least one project check before '
      'arming.',
    );
  }
  if (input.projectCheckCount <= 0) {
    return UnattendedRefusal(
      UnattendedRefusalKind.noProjectChecks,
      '$repository has no project check. An unattended run needs at least one '
      'command that says whether the work still stands, because there is '
      'nobody there to look — add one before arming.',
    );
  }

  if (!input.agentInstalled) {
    return UnattendedRefusal(
      UnattendedRefusalKind.agentUnavailable,
      '$agent is no longer installed where this automation was armed, so there '
      'is nothing here to start. Nothing is substituted for it — reinstall it, '
      'or arm this on an agent that is here.',
    );
  }

  final permits = input.permits;
  if (permits == null) {
    return UnattendedRefusal(
      UnattendedRefusalKind.permissionModeUnknown,
      'Karmashala has not established which permission modes $agent has, so it '
      'starts under its own default and nothing here can govern it. An '
      'automation cannot be armed on a mode nobody has established.',
    );
  }
  if (permissionModeCanPrompt(permits)) {
    final mode = input.permissionLabel.trim().isEmpty
        ? permits.label
        : input.permissionLabel.trim();
    final evidence = input.permissionEvidence.trim();
    return UnattendedRefusal(
      UnattendedRefusalKind.permissionModeCanPrompt,
      '"$mode" stops and asks $agent\'s user before it acts, and an automation '
      'fires with nobody there to answer. The mode is refused rather than '
      'quietly widened — pick one of $agent\'s own modes that does not prompt.'
      '${evidence.isEmpty ? '' : ' ($evidence)'}',
    );
  }

  switch (input.reach) {
    case UnattendedReach.reachable:
      return null;
    case UnattendedReach.unnamed:
      return UnattendedRefusal(
        UnattendedRefusalKind.environmentUnnamed,
        'Karmashala cannot say where $repository\'s agent would run, so it '
        'cannot check these preconditions where they would matter'
        '${_because(input.reachReason)}.',
      );
    case UnattendedReach.unreachable:
      return UnattendedRefusal(
        UnattendedRefusalKind.environmentUnreachable,
        'Karmashala cannot reach where $repository\'s agent would run'
        '${_because(input.reachReason)}. An automation is armed here and fires '
        'here, so a checkout this app cannot run a command in cannot be armed.',
      );
  }
}

/// Whether an unattended fire may proceed.
bool canRunUnattended(UnattendedGateInput input) =>
    unattendedRefusal(input) == null;

String _because(String reason) {
  final trimmed = reason.trim();
  if (trimmed.isEmpty) return '';
  return ': ${trimmed.endsWith('.') ? trimmed.substring(0, trimmed.length - 1) : trimmed}';
}
