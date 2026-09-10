import 'package:agent_cli/descriptors.dart';

/// When an automation fires: a cron expression, or one absolute instant. Two
/// kinds, because a one-shot stored as a cron loses that it is *over*.
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

/// An agent run a person authorised in advance. [armedAt] is the authorisation;
/// there is no `armed_by`, because an agent could write it and make it lie.
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

  final String prompt;

  /// The mode it runs under, canonical (`mode=auto`). Null means nobody chose,
  /// which resolves to the agent's declared default.
  final PermissionSelection? permissionMode;

  /// Paused automations keep their row, their runs and their arming.
  final bool enabled;

  /// When a person armed it — the floor a missed-fire sweep counts from.
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
