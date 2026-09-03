/// Lifecycle status of a [Session] — **the durable half**, kept by the row
/// rather than observed live.
///
/// Kept deliberately small in Loop 1; the session engine (Loop 6) drove
/// transitions between these states, and no in-app session uses it any more —
/// every one of them runs in a PTY, so what actually writes this now is
/// `SessionLauncher` (running/failed), `SessionAdoptionService` (running) and
/// `SessionLivenessReconciler` ([unknown]).
///
/// It is **not** the same question as `AgentActivityStatus`, which says what the
/// agent is doing this second. A session can be `running` with its agent idle,
/// waiting for the user to type. See `NativeSessionRow`, which draws both.
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
  /// it, and nothing can now: the app was restarted, its pane stopped, or it
  /// was launched into a terminal window we do not own.
  ///
  /// Deliberately *not* an ending — `endingOfStatus` answers null for it, the
  /// same silence `SessionEnding.lostTrack` already gets — and deliberately not
  /// a claim that anything is running. The conversation is still there and
  /// resuming it makes the row `running` again.
  ///
  /// It exists because without it there was no honest answer at all. Nothing
  /// moved a row out of [running] when its process went away, so a session that
  /// ended three days ago went on drawing a play glyph in the Explorer, and
  /// every consumer that filters on `== running` — the checkpoint recorder, the
  /// follow-up observer, the CLI title sync's permanent store sweep — went on
  /// paying for it. The other five words were all worse: `completed`, `failed`
  /// and `cancelled` each assert an ending we did not witness, and `created`
  /// and `idle` are both live states.
  ///
  /// Also the fallback for a status word this build cannot read (see
  /// `SessionDao._statusFrom`), which is the same statement about the same row.
  unknown;

  /// Whether this status asserts that something is running right now.
  ///
  /// The predicate `SessionLivenessReconciler` acts on: exactly these are the
  /// claims that can be contradicted by looking at the panes. [created] is not
  /// one — a row that was never started is not claiming to be live — and
  /// neither is [unknown], which is what the contradiction produces.
  bool get claimsLive =>
      this == SessionStatus.running || this == SessionStatus.idle;
}
