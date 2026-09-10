/// How much of the UI isolate a pane's output is entitled to, by how visible it
/// is: 100 panes at frame cadence cost 62 ms against a 16.7 ms budget.
enum IngestTier {
  /// In the active tab: the user is looking at it, with a reserved share of the
  /// frame no number of background panes can take.
  hot,

  /// Open in another tab: it must stay correct, but nobody is watching it draw.
  /// Drains at a lower cadence and out of a *shared* pool, so the cost of every
  /// hidden pane put together is bounded rather than multiplied.
  warm,

  /// Detached — running with no tab at all. Its scrollback is spooled unparsed,
  /// but its *screen* is still redrawn, at most once a second.
  cold,
}
