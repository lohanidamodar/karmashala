/// What terminal persistence owes and what its last write cost. Diagnostics
/// only — a dirty count that never falls is work not being written.
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

  /// How many panes it wrote. Fewer than were dirty means it hit its budget — a
  /// pass that keeps being cut off says writes are falling behind.
  final int panes;

  final Duration took;

  /// When the pass started, on the controller's uptime clock.
  final Duration at;
}
