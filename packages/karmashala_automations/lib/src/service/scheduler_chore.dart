/// Something else that rides the scheduler's one timer (worktree cleanup).
abstract interface class SchedulerChore {
  /// When it is next due, or null for never.
  DateTime? nextDue({required DateTime availableSince});

  /// Starts it when it is due by [now].
  void startIfDue(DateTime now, {required DateTime availableSince});
}
