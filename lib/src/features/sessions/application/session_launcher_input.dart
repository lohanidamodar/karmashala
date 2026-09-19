part of 'session_launcher.dart';

/// Text and keystrokes going **into** a session already running. There is no
/// second write path into an agent, so these three verbs are the whole of it.
extension SessionInputVerbs on SessionLauncher {
  /// The attribution for text one session is putting into another's input, or
  /// `null` — naming a sender we cannot read would be inventing provenance.
  SessionAttribution? attributionFor(String? senderSessionId) {
    if (senderSessionId == null) return null;
    final sender = _ref.read(sessionDaoProvider).getById(senderSessionId);
    if (sender == null) return null;
    return SessionAttribution(sessionId: sender.id, title: sender.title);
  }

  /// Types [text] into a PTY-hosted session, exactly as if the user had; there
  /// is no second write path. False when the session has no live pane.
  bool sendTo(String sessionId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    // CR, not LF: a PTY line discipline reads CR as "submit". The `Ctrl+E` ends
    // Codex's paste burst, which would otherwise fold the Return to a newline.
    terminal
      ..textInput(trimmed)
      ..textInput(kEndOfLineKey)
      ..textInput('\r');
    return true;
  }

  /// Presses [keys] in the terminal — a keystroke, never trimmed — and records
  /// what the agent's own table says it authorised. False if there is no pane.
  bool answerPrompt(
    String sessionId,
    String keys, {
    String decidedBy = 'the user',
    String? decidedBySessionId,
  }) {
    if (keys.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    terminal.textInput(keys);
    _recordAnswer(
      sessionId,
      keys,
      decidedBy: decidedBy,
      decidedBySessionId: decidedBySessionId,
    );
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

  /// Writes the answered prompt to the decision record — **a table lookup, not
  /// an interpretation**; a keystroke matching neither answer records nothing.
  void _recordAnswer(
    String sessionId,
    String keys, {
    required String decidedBy,
    required String? decidedBySessionId,
  }) {
    final session = _ref.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return;
    final agentId = _ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
    if (agentId == null) return;
    final rules =
        _ref.read(agentRegistryProvider).byId(agentId)?.approval ??
        const AgentApprovalRules();
    final granted = rules.approve?.keys == keys;
    final answer = granted ? rules.approve : rules.deny;
    if (answer == null || answer.keys != keys) return;
    _ref
        .read(decisionRecorderProvider)
        .recordApproval(
          sessionId: sessionId,
          granted: granted,
          effect: answer.effect,
          answerLabel: answer.label,
          decidedBy: decidedBy,
          decidedBySessionId: decidedBySessionId,
        );
  }
}
