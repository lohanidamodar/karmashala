import '../../agents/domain/agent_permission_support.dart';

/// When an automation fires: a recurring cron expression, or one absolute
/// instant.
///
/// Two kinds and no third. A cron expression is a rule that outlives any one
/// occurrence; a one-shot is a single instant that either happened or was
/// missed. Folding the second into the first — storing `at 03:00 on the 9th` as
/// a cron — loses the fact that it is *over* once it has fired, which is
/// exactly what makes a one-shot catchable-up rather than silently rolled to
/// tomorrow.
class AutomationSchedule {
  const AutomationSchedule.cron(String this.cron) : firesAt = null;

  const AutomationSchedule.once(DateTime this.firesAt) : cron = null;

  /// A five-field cron expression, in the machine's own timezone. Null for a
  /// one-shot.
  final String? cron;

  /// The absolute instant a one-shot is due, UTC. Null for a cron.
  final DateTime? firesAt;

  bool get isOnce => firesAt != null;
  bool get isRecurring => cron != null;

  /// What a row stores. Exactly one of the two columns is ever set.
  String? get cronText => cron;

  @override
  bool operator ==(Object other) =>
      other is AutomationSchedule &&
      other.cron == cron &&
      other.firesAt == firesAt;

  @override
  int get hashCode => Object.hash(cron, firesAt);

  @override
  String toString() =>
      isOnce ? 'once at ${firesAt!.toIso8601String()}' : 'cron "$cron"';
}

/// An agent run a person authorised in advance.
///
/// **[armedAt] is the authorisation**, and there is deliberately no
/// `armed_by`: this app has one user, arming happens only in the UI, and a
/// column naming who did it would be a claim the schema cannot keep — an agent
/// that could write this row would make the column lie. The absence *is* the
/// statement, and the MCP catalogue says the same thing from the other side.
class Automation {
  const Automation({
    required this.id,
    required this.repositoryId,
    required this.name,
    required this.schedule,
    required this.agentInstallationId,
    required this.prompt,
    required this.permissionMode,
    required this.enabled,
    required this.armedAt,
  });

  final String id;

  /// The checkout it runs in. Its environment is where the gate preflights.
  final String repositoryId;

  /// What the user calls it, so a run row and a refusal name the same thing.
  final String name;

  final AutomationSchedule schedule;

  /// The installation to start — an agent *and* the environment it lives in.
  /// Never resolved to another one; see `UnattendedGateInput.agentInstalled`.
  final String agentInstallationId;

  /// What the agent is told when it comes up.
  final String prompt;

  /// The mode it runs under, canonical (`mode=auto`). Null means nobody chose,
  /// which resolves to the agent's declared default — and the gate then reads
  /// that default's rung like any other.
  final PermissionSelection? permissionMode;

  /// Paused automations keep their row, their runs and their arming.
  final bool enabled;

  /// When a person armed it. The floor a missed-fire sweep counts from: an
  /// occurrence before this moment was never ours to claim.
  final DateTime armedAt;

  Automation copyWith({
    String? name,
    AutomationSchedule? schedule,
    String? agentInstallationId,
    String? prompt,
    PermissionSelection? permissionMode,
    bool? enabled,
    DateTime? armedAt,
  }) => Automation(
    id: id,
    repositoryId: repositoryId,
    name: name ?? this.name,
    schedule: schedule ?? this.schedule,
    agentInstallationId: agentInstallationId ?? this.agentInstallationId,
    prompt: prompt ?? this.prompt,
    permissionMode: permissionMode ?? this.permissionMode,
    enabled: enabled ?? this.enabled,
    armedAt: armedAt ?? this.armedAt,
  );

  @override
  String toString() => 'Automation($id, $name, $schedule, enabled: $enabled)';
}
