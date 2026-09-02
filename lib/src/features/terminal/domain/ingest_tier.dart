/// How much of the UI isolate a pane's output is entitled to, by how visible
/// the pane is.
///
/// Every live pane used to be drained and VT-parsed at frame cadence whether or
/// not anyone could see it. `tool/benchmark/terminal_ingest_bench.dart` measured
/// what that costs: with 100 panes all producing output, one frame's ingestion
/// took 62 ms against a 16.7 ms budget, linear in the number of panes, and armed
/// 100 watchdog timers per frame. Painting only the active tab does not help,
/// because the cost is on the *producer* side.
///
/// The tiers are the fix. They are set by `TerminalSessionsController` from the
/// only thing that decides them — where the pane is in the layout — and never
/// by the pane itself.
enum IngestTier {
  /// In the active tab: the user is looking at it.
  ///
  /// Today's path exactly, with a reserved share of the frame budget that no
  /// number of background panes can take. This is the audit's key point: a
  /// per-pane watchdog cannot protect the active pane, because it has no idea
  /// what the other ninety-nine are doing.
  hot,

  /// Open in another tab: it must stay correct, but nobody is watching it draw.
  ///
  /// Drains at a lower cadence and out of a *shared* pool, so the cost of every
  /// hidden pane put together is bounded rather than multiplied.
  warm,

  /// Detached — running with no tab at all.
  ///
  /// Its scrollback is not parsed: output goes into a bounded raw spool and is
  /// replayed into the buffer only when the session is brought back. A cold
  /// pane costs no buffer, no timer and no frame.
  ///
  /// Its *screen* is another matter. `terminalTailLines` reads the bottom of
  /// the grid to tell whether an agent is waiting for approval, and a session
  /// with no tab is exactly the session nobody is watching for — so a cold pane
  /// redraws its screen, at most once a second, out of the same shared pool a
  /// warm pane draws on, and trims straight back to the viewport. See
  /// `ColdScreen`.
  cold,
}
