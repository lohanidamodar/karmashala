/// What became of one occurrence of an automation. Five values because there
/// are five things to tell a person; [missed] is the one this feature is for.
enum AutomationRunState {
  /// The checkout was busy, so this fire is waiting its turn. **Not a race
  /// lost** — one unattended owner per workspace, and this is the queue.
  queued,

  running,

  /// Its session ended without an error.
  finished,

  /// It could not start, or its session stopped in error. [AutomationRun.reason]
  /// says which and why — a gate refusal at fire time lands here.
  failed,

  /// It was due while the app was not running, and too late to catch up.
  /// Always carries a reason.
  missed,

  /// A state this build does not know — a row from a newer schema. Never
  /// written, only read, like `SessionEnding.unrecognised`.
  unrecognised;

  static AutomationRunState fromName(String? name) => values.firstWhere(
    (state) => state.name == name,
    orElse: () => AutomationRunState.unrecognised,
  );

  /// Whether something is still expected to happen for this row.
  bool get isLive =>
      this == AutomationRunState.queued || this == AutomationRunState.running;

  String get label => switch (this) {
    AutomationRunState.queued => 'Queued',
    AutomationRunState.running => 'Running',
    AutomationRunState.finished => 'Finished',
    AutomationRunState.failed => 'Failed',
    AutomationRunState.missed => 'Missed',
    AutomationRunState.unrecognised => 'Recorded in a way this build cannot read',
  };
}

/// One occurrence of an automation, and what happened to it.
class AutomationRun {
  const AutomationRun({
    required this.id,
    required this.automationId,
    required this.scheduledFor,
    required this.firedAt,
    required this.state,
    required this.reason,
    this.baseCheckpointId,
    this.sessionId,
    this.finishedAt,
    this.commitsMade,
    this.checksObservedAt,
  });

  final String id;
  final String automationId;

  /// The occurrence this row is about — when it was *due*, which for a missed
  /// row is not when it was recorded.
  final DateTime scheduledFor;

  /// When this row was written; a verdict with no age names no moment.
  final DateTime firedAt;

  final AutomationRunState state;

  /// Why this row reads the way it does. **Never empty for a `missed` or a
  /// `failed`** — a miss with no reason is the silence this feature removes.
  final String reason;

  /// The checkpoint of the tree as it stood before the agent touched it. What
  /// "restore the files" restores to; null when the run never got that far.
  final String? baseCheckpointId;

  /// The session the agent ran in, once one was started.
  final String? sessionId;

  final DateTime? finishedAt;

  /// How many commits the run's session left on the branch, counted when it
  /// settled. Null means not counted, never zero.
  final int? commitsMade;

  /// When this run's project checks were looked at, or null when nothing has
  /// looked yet — a different fact from a checkout that configures none (§19).
  final DateTime? checksObservedAt;

  Duration? get duration => finishedAt?.difference(firedAt);

  AutomationRun copyWith({
    AutomationRunState? state,
    String? reason,
    String? baseCheckpointId,
    String? sessionId,
    DateTime? finishedAt,
    int? commitsMade,
    DateTime? checksObservedAt,
  }) => AutomationRun(
    id: id,
    automationId: automationId,
    scheduledFor: scheduledFor,
    firedAt: firedAt,
    state: state ?? this.state,
    reason: reason ?? this.reason,
    baseCheckpointId: baseCheckpointId ?? this.baseCheckpointId,
    sessionId: sessionId ?? this.sessionId,
    finishedAt: finishedAt ?? this.finishedAt,
    commitsMade: commitsMade ?? this.commitsMade,
    checksObservedAt: checksObservedAt ?? this.checksObservedAt,
  );

  @override
  String toString() => 'AutomationRun($id, ${state.name}, due $scheduledFor)';
}
