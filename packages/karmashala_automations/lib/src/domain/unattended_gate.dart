/// The rules that decide whether an agent may be started with nobody watching.
/// Pure and over plain inputs, so one gate serves every unattended entry point.
library;

import 'package:agent_cli/descriptors.dart';

/// Where the agent would run, as the environment resolver answered — three
/// values, and `EnvironmentRefusal.sshUnavailable` maps here, not re-derived.
enum UnattendedReach {
  /// Named, and a command can be run there from this app.
  reachable,

  /// Nothing says where this checkout's commands would run.
  unnamed,

  /// Named, and this app cannot reach it.
  unreachable,
}

/// Why an automation may not fire with nobody watching. Named values so a
/// surface can decide where to send the user, while the sentence stays one.
enum UnattendedRefusalKind {
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

/// One refusal: what rule said no, in the words a person reads. Exactly one
/// type, so a [reason] shown on hover is the reason arming would throw.
class UnattendedRefusal {
  const UnattendedRefusal(this.kind, this.reason);

  final UnattendedRefusalKind kind;

  /// One or two sentences, fit to show and to throw with. Never empty.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is UnattendedRefusal &&
      other.kind == kind &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(kind, reason);

  @override
  String toString() => reason;
}

/// Everything the rules read, already looked up.
class UnattendedGateInput {
  const UnattendedGateInput({
    required this.repositoryName,
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

  final String agentName;

  /// Whether the installation this was armed on is still here — refused rather
  /// than resolved to another, since it names *this* agent on *this* machine.
  final bool agentInstalled;

  /// The most the chosen selection permits, or null when nobody has established
  /// this agent's modes — the absence of a claim, never a permissive one.
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

/// Whether a mode still stops and asks a human: [PermissionRisk.ask] and
/// [PermissionRisk.acceptEdits] do. A null rung is [unattendedRefusal]'s (§19).
bool permissionModeCanPrompt(PermissionRisk risk) =>
    risk == PermissionRisk.ask || risk == PermissionRisk.acceptEdits;

/// Why this automation may not fire unattended, or `null` when it may: its
/// agent must be here, must never stop to ask, and must be reachable. A check
/// is an optional step, never a precondition.
UnattendedRefusal? unattendedRefusal(UnattendedGateInput input) {
  final repository = input.repositoryName.trim().isEmpty
      ? 'this checkout'
      : input.repositoryName.trim();
  final agent = input.agentName.trim().isEmpty
      ? 'this agent'
      : input.agentName.trim();

  if (!input.agentInstalled) {
    return UnattendedRefusal(
      UnattendedRefusalKind.agentUnavailable,
      '$agent is no longer installed where this automation runs, so there is '
      'nothing here to start. Nothing is put in its place — reinstall it, or '
      'pick an agent that is here.',
    );
  }

  final permits = input.permits;
  if (permits == null) {
    return UnattendedRefusal(
      UnattendedRefusalKind.permissionModeUnknown,
      'Karmashala does not know which permission modes $agent has, so it '
      'would start under its own default and nothing here could keep it from '
      'stopping to ask. Pick an agent whose modes are known.',
    );
  }
  if (permissionModeCanPrompt(permits)) {
    final mode = input.permissionLabel.trim().isEmpty
        ? permits.label
        : input.permissionLabel.trim();
    final evidence = input.permissionEvidence.trim();
    return UnattendedRefusal(
      UnattendedRefusalKind.permissionModeCanPrompt,
      '"$mode" stops and asks $agent\'s user before it acts, and nobody is '
      'there to answer an unattended run. It is not quietly widened — pick '
      'one of $agent\'s own modes that does not ask.'
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
        '${_because(input.reachReason)}. An automation starts its agent from '
        'here, so it cannot run in a checkout this app cannot run a command in.',
      );
  }
}

bool canRunUnattended(UnattendedGateInput input) =>
    unattendedRefusal(input) == null;

String _because(String reason) {
  final trimmed = reason.trim();
  if (trimmed.isEmpty) return '';
  return ': ${trimmed.endsWith('.') ? trimmed.substring(0, trimmed.length - 1) : trimmed}';
}
