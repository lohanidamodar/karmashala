/// What terminal persistence currently owes, and what its last write cost.
///
/// Diagnostics only: nothing in the app behaves differently because of these
/// numbers. They exist because "the app feels like it is falling behind" was a
/// report nobody could answer. Watch [dirtyPanes] and [oldestUnsaved] together
/// — a dirty count that rises and falls is an autosave doing its job; one that
/// does not fall, or an age that keeps climbing, is work not being written.
class PersistenceTelemetry {
  const PersistenceTelemetry({
    required this.dirtyPanes,
    required this.livePanes,
    required this.oldestUnsaved,
    required this.lastWrite,
  });

  /// Panes whose buffer has moved since it was last encoded.
  final int dirtyPanes;

  /// Panes with an instance behind them, dirty or not — the denominator that
  /// makes [dirtyPanes] mean something.
  final int livePanes;

  /// How long the pane that has been waiting longest has owed a write, or null
  /// when nothing is owed. Measured on a monotonic clock, so it cannot be
  /// distorted by the wall clock moving.
  final Duration? oldestUnsaved;

  /// The last completed scrollback write, or null when none has run yet —
  /// reported as "not recorded" rather than as a zero that reads like a
  /// measurement.
  final ScrollbackWrite? lastWrite;
}

/// One completed pass of `saveDirtyScrollback`.
class ScrollbackWrite {
  const ScrollbackWrite({
    required this.panes,
    required this.took,
    required this.at,
  });

  /// How many panes it wrote. Fewer than were dirty means it hit its budget,
  /// which is the interesting case rather than a fault: the budget exists so a
  /// write cannot hold a frame, and a pass that keeps being cut off says the
  /// layout is producing faster than it is being saved.
  final int panes;

  final Duration took;

  /// When the pass started, on the controller's uptime clock.
  final Duration at;
}
