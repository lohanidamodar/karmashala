/// Lifecycle status of a [Session].
///
/// Kept deliberately small in Loop 1; the session engine (Loop 6) drives
/// transitions between these states.
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
}
