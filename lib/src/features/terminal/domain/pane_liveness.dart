/// Whether a process is running behind a terminal pane's buffer.
///
/// A pane's buffer and the process that filled it have separate lifetimes, and
/// replayed history from last week must not look like a shell waiting for
/// input. It says nothing about whether a tab is *showing* the pane — that is
/// attachment, and it belongs to the sessions controller.
enum PaneLiveness {
  /// A process is running. Keystrokes reach it and its output is arriving.
  live,

  /// The process exited — on its own, because the user ended the session, or
  /// because it never started (a pane that failed to spawn).
  exited,

  /// Rebuilt from a stored record after a restart. Nothing has ever run in this
  /// buffer, and no command is re-executed unless the user asks. The panes a
  /// launch does give a process back never reach this state — they are built
  /// live — and `shouldRestartOnLaunch` is the one place that decides which.
  restored;

  /// Whether a process is running behind the buffer.
  bool get isLive => this == PaneLiveness.live;
}
