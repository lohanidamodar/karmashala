/// Whether a process is running behind a terminal pane's buffer.
///
/// A pane's buffer and the process that filled it have separate lifetimes, and
/// the UI has to tell them apart: replayed history from last week must not look
/// like a shell waiting for input. This names the three cases so nothing has to
/// infer "is this real?" from the buffer's contents.
///
/// It says nothing about whether a tab is *showing* the pane — that is
/// attachment, and it belongs to the sessions controller. A detached session is
/// [live]; a restored one that nobody has started is [restored] whether or not
/// it sits in a tab.
enum PaneLiveness {
  /// A process is running. Keystrokes reach it and its output is arriving.
  live,

  /// The process exited — on its own, because the user ended the session, or
  /// because it never started (a pane that failed to spawn).
  exited,

  /// Rebuilt from a stored record after a restart. Nothing has ever run in this
  /// buffer: everything in it is replayed history, and no command has been (or
  /// will be) re-executed unless the user asks.
  restored;

  /// Whether a process is running behind the buffer.
  bool get isLive => this == PaneLiveness.live;
}
