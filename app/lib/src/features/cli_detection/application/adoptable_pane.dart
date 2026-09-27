/// One terminal pane, as this app sees it: what the launched-session rebind
/// reads. A plain value rather than a `TerminalInstance`, so it is drivable
/// with no PTY.
class AdoptablePane {
  const AdoptablePane({
    required this.paneId,
    required this.workingDirectory,
    required this.isLive,
    required this.hostsLaunchedSession,
    this.lastCommandId,
    this.lastCommandLine,
    this.lastCommandRunning = true,
  });

  final String paneId;

  /// Where the pane was opened, or null for a pane with no recorded
  /// directory.
  final String? workingDirectory;

  final bool isLive;

  /// Whether the app opened this pane to run a session it already has a row
  /// for: the *launched* case, never adopted.
  final bool hostsLaunchedSession;

  /// The newest OSC 133 command block's id, or null for a shell with no
  /// integration or one that has run nothing.
  final String? lastCommandId;

  /// That block's command line, once the shell said it is running.
  final String? lastCommandLine;

  /// Whether that block still runs. True when the shell is mute.
  final bool lastCommandRunning;
}
