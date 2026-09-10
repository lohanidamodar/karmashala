/// Lifecycle status of a [Session] — **the durable half**, kept by the row
/// rather than observed live. What writes it now is `SessionLauncher`
/// (running/failed), `SessionAdoptionService` (running) and
/// `SessionLivenessReconciler` ([unknown]).
///
/// **Not** the same question as `AgentActivityStatus`, which says what the agent
/// is doing this second: a session can be `running` with its agent idle.
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

  /// **We lost sight of it.** It was running the last time anything could see
  /// it, and nothing can now: the app restarted, its pane stopped, or it was
  /// launched into a terminal window we do not own.
  ///
  /// Not an ending, and not a claim that anything is running — resuming makes
  /// the row `running` again. The other five words were worse: three assert an
  /// ending we did not witness, and `created` and `idle` are live states. Also
  /// the fallback for a status word this build cannot read.
  unknown;

  /// Whether this status asserts that something is running right now — the
  /// predicate `SessionLivenessReconciler` acts on. [created] is not one (a row
  /// never started is not claiming to be live), and neither is [unknown], which
  /// is what the contradiction produces.
  bool get claimsLive =>
      this == SessionStatus.running || this == SessionStatus.idle;

  /// Whether this row has already recorded how the session ended — the guard
  /// `SessionOutcomeWriter` turns on, so a late hook cannot replace the user's
  /// `cancelled` with its own `completed`. [unknown] is deliberately not one: a
  /// payload that finally says how it ended improves on it.
  bool get isEnded =>
      this == SessionStatus.completed ||
      this == SessionStatus.failed ||
      this == SessionStatus.cancelled;

  /// **The word to show a reader**, given whether anything can see the session
  /// running right now. A row claiming to be live with no live pane behind it is
  /// a confident false statement; the honest sentence is what is actually true —
  /// the agent never told us it stopped.
  String labelWhen({required bool hostedLive}) =>
      claimsLive && !hostedLive ? 'no ending was reported' : name;
}
