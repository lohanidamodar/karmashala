/// Lifecycle status of a [Session] — **the durable half**, kept by the row
/// rather than observed live. Not `AgentActivityStatus`, which is this second.
enum SessionStatus {
  /// Created but not yet started.
  created,

  /// Actively running an agent.
  running,

  /// Started but currently idle/waiting.
  idle,

  /// Finished successfully.
  completed,

  /// Ended in error.
  failed,

  /// Cancelled by the user.
  cancelled,

  /// **We lost sight of it**: it was running and nothing can see it now. Not an
  /// ending and not a claim — resuming makes the row `running` again.
  unknown;

  /// Whether this status asserts something is running right now — the predicate
  /// `SessionLivenessReconciler` acts on. [unknown] is what it produces.
  bool get claimsLive =>
      this == SessionStatus.running || this == SessionStatus.idle;

  /// Whether this row has already recorded how the session ended, so a late
  /// hook cannot replace the user's `cancelled` with its own `completed`.
  bool get isEnded =>
      this == SessionStatus.completed ||
      this == SessionStatus.failed ||
      this == SessionStatus.cancelled;

  /// **The word to show a reader**, given whether anything can see it running.
  /// `running` with no live pane behind it is a confident false statement.
  String labelWhen({required bool hostedLive}) =>
      claimsLive && !hostedLive ? 'no ending was reported' : name;
}
