/// One session the session host holds, as a phone's list needs it.
typedef HostedSessionView = ({
  String hostSessionId,
  String command,
  bool running,
  int? exitCode,
  DateTime startedAt,
});

/// What the session host itself can show and do with the sessions it runs —
/// the only answers it has for a phone while no desktop app is connected. The
/// host implements it over its registry; this package never sees a PTY.
abstract interface class CompanionScreens {
  /// Every session the host holds, running or ended.
  List<HostedSessionView> sessions();

  /// The one named [hostSessionId], or null when the host does not hold it.
  HostedSessionView? find(String hostSessionId);

  /// The session's screen as plain text, oldest line first, or null when the
  /// host keeps no screen for it (a session read back from disk).
  String? screenText(String hostSessionId);

  /// How much output the session has produced, which moves whenever its
  /// screen can have — or null when the host does not hold it.
  int? outputOffset(String hostSessionId);

  /// Types [text] into the running session and presses Enter. Throws
  /// `RemoteApiRefusal` naming why when it cannot: not running, or somebody
  /// else is driving it.
  Future<void> type(String hostSessionId, String text);
}
