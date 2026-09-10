part of 'session_launcher.dart';

/// Text and keystrokes going **into** a session that is already running.
///
/// There is no second write path into an agent, so the three verbs here are the
/// whole of it and their differences are deliberate: [SessionLauncher.sendTo]
/// delivers a *message* (trimmed, submitted), [SessionLauncher.answerPrompt]
/// presses a **keystroke** the agent itself named, and `_recordAnswer` writes
/// down what that keystroke authorised by looking it up in the agent's own
/// table rather than interpreting it. [SessionLauncher.attributionFor] is the
/// same act from the other end.
extension SessionInputVerbs on SessionLauncher {
  /// The attribution for text a *session* is putting into another session's
  /// input, or `null` when no session can be named for it. Two callers, one
  /// prefix, built in one place because the strip rebuilds the line rather than
  /// parsing it. Null for a row that has gone: naming a sender we cannot read
  /// would be inventing provenance.
  SessionAttribution? attributionFor(String? senderSessionId) {
    if (senderSessionId == null) return null;
    final sender = _ref.read(sessionDaoProvider).getById(senderSessionId);
    if (sender == null) return null;
    return SessionAttribution(sessionId: sender.id, title: sender.title);
  }

  /// Types [text] into a PTY-hosted session, exactly as if the user had — there
  /// is no second write path, so a message sent from chat and one typed into
  /// the pane are indistinguishable to the CLI. Returns false when the session
  /// has no live pane, so the caller can say so rather than drop the message.
  bool sendTo(String sessionId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    // A carriage return, not a newline: a PTY line discipline reads CR as
    // "submit", and a bare LF leaves the text sitting in the agent's composer.
    // The `Ctrl+E` is what makes that CR arrive as a keypress — Codex's
    // `paste_burst.rs` reads characters that arrive with no gap as a paste and
    // folds a Return inside that run into a newline, and anything that is not a
    // character ends the run.
    terminal
      ..textInput(trimmed)
      ..textInput(kEndOfLineKey)
      ..textInput('\r');
    return true;
  }

  /// Answers an agent's on-screen prompt by pressing [keys] in its terminal.
  ///
  /// Separate from [sendTo] because the two are different acts: an answer is a
  /// **keystroke** — `\r`, `\x1b` — where trimming would erase the whole
  /// payload and an appended return would press a second key nobody asked for.
  /// [keys] must come from the agent's own [AgentApprovalRules]; nothing here
  /// invents a binding. Returns false when the session has no live pane.
  ///
  /// **This is where an approval reaches the decision record**, and the only
  /// place both answering paths meet, so the packet carries what the user
  /// allowed however they allowed it. [decidedBy] names who answered.
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

  /// Writes the answered prompt to the session's decision record, when the
  /// keystroke is one the agent itself named — **a table lookup, not an
  /// interpretation**, against the same [AgentApprovalRules] the card read to
  /// draw the button. Keys that match neither answer record *nothing*: guessing
  /// at what an unrecognised keystroke authorised is what the record must never
  /// contain.
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
