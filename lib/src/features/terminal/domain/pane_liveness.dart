/// Whether a process is running behind a pane's buffer — replayed history must
/// not look like a shell waiting for input. Not whether a tab is showing it.
enum PaneLiveness {
  /// A process is running. Keystrokes reach it and its output is arriving.
  live,

  /// The process exited — on its own, because the user ended the session, or
  /// because it never started (a pane that failed to spawn).
  exited,

  /// Rebuilt from a stored record after a restart: nothing has ever run in this
  /// buffer, and no command is re-executed unless the user asks.
  restored;

  /// Whether a process is running behind the buffer.
  bool get isLive => this == PaneLiveness.live;
}
