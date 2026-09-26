part of 'session_launcher.dart';

/// Text and keystrokes going **into** a session already running. There is no
/// second write path into an agent, so these verbs are the whole of it; an
/// answer to a prompt is `SessionPromptAnswers`, which presses through
/// [pressKeys] and files the decision itself.
extension SessionInputVerbs on SessionLauncher {
  /// The attribution for text one session is putting into another's input, or
  /// `null` — naming a sender we cannot read would be inventing provenance.
  SessionAttribution? attributionFor(String? senderSessionId) {
    if (senderSessionId == null) return null;
    final sender = _ref.read(sessionDaoProvider).getById(senderSessionId);
    if (sender == null) return null;
    return SessionAttribution(sessionId: sender.id, title: sender.title);
  }

  /// Types [text] into a PTY-hosted session and presses Return, exactly as if
  /// the user had; there is no second write path. False when the session has
  /// no live pane. A send that reads its Return back off the screen goes
  /// through [SessionMessageTypist], which types with [typeInto] and presses
  /// the Return itself.
  bool sendTo(String sessionId, String text) {
    if (!typeInto(sessionId, text)) return false;
    // CR, not LF: a PTY line discipline reads CR as "submit".
    return pressKeys(sessionId, '\r');
  }

  /// Types [text] into a PTY-hosted session, without the Return that sends it.
  /// False when the session has no live pane.
  bool typeInto(String sessionId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    // The `Ctrl+E` ends Codex's paste burst, which would otherwise fold the
    // Return that follows into a newline.
    terminal
      ..textInput(trimmed)
      ..textInput(kEndOfLineKey);
    return true;
  }

  /// Presses [keys] in the terminal and records nothing — for moving through a
  /// menu, where what a key authorises is the option it lands on, not the key.
  /// False if there is no pane.
  bool pressKeys(String sessionId, String keys) {
    if (keys.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    terminal.textInput(keys);
    return true;
  }
}
