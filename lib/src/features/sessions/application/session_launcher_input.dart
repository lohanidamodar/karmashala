part of 'session_launcher.dart';

/// Text and keystrokes going **into** a session that is already running.
///
/// There is no second write path into an agent: a message sent from the chat
/// composer and one typed into the pane are indistinguishable to the CLI,
/// which is what "the composer and the terminal are two views of one session"
/// means at the input end. So the three verbs here are the whole of it, and
/// the differences between them are deliberate rather than incidental —
/// [SessionLauncher.sendTo] delivers a *message* (trimmed, submitted),
/// [SessionLauncher.answerPrompt] presses a **keystroke** the agent itself
/// named, and `_recordAnswer` writes down what that keystroke authorised by
/// looking it up in the agent's own table rather than interpreting it.
///
/// [SessionLauncher.attributionFor] is here because it is the same act seen
/// from the other end: the one prefix that says which session put text into
/// another, built in one place because the strip rebuilds it rather than
/// parsing it.
///
/// An extension in a `part` for the reason `session_launcher.dart` gives.
extension SessionInputVerbs on SessionLauncher {
  /// The attribution for text a *session* is putting into another session's
  /// input, or `null` when no session can be named for it.
  ///
  /// Two callers, one prefix: the opening prompt of a session an agent spawned
  /// (where [senderSessionId] is the parent), and `session_send` relaying a
  /// message (where it is the caller the MCP transport authenticated). They
  /// build the line from the same place on purpose — the strip rebuilds it
  /// rather than parsing it, so a second format would be a line nothing knows
  /// how to remove.
  ///
  /// Null for a sender with no session of its own and for a row that has gone.
  /// Naming a sender we cannot read would be inventing provenance, which is the
  /// failure the prefix exists to close rather than a smaller version of it.
  SessionAttribution? attributionFor(String? senderSessionId) {
    if (senderSessionId == null) return null;
    final sender = _ref.read(sessionDaoProvider).getById(senderSessionId);
    if (sender == null) return null;
    return SessionAttribution(sessionId: sender.id, title: sender.title);
  }

  /// Types [text] into a PTY-hosted session, exactly as if the user had.
  ///
  /// This is what "the composer and the terminal are two views of one session"
  /// means at the input end: there is no second write path into the agent, so a
  /// message sent from chat and one typed into the pane are indistinguishable to
  /// the CLI, and neither can get out of step with the other.
  ///
  /// Returns false when the session has no live pane — a restored record, an
  /// external terminal, or a session that has ended — so the caller can say so
  /// rather than silently dropping the message.
  bool sendTo(String sessionId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final terminal = _liveTerminalFor(sessionId);
    if (terminal == null) return false;
    // A carriage return, not a newline: a PTY line discipline reads CR as
    // "submit", and a bare LF leaves the text sitting in the agent's composer.
    //
    // The `Ctrl+E` between them is what makes that CR arrive as a keypress.
    // Measured 2026-09-08 against a real ConPTY: Codex 0.153.4 leaves the
    // message sitting in its composer, on Windows and in WSL alike, because
    // `paste_burst.rs` reads characters that arrive with no gap as a paste and
    // folds a Return inside that run into a newline. Anything that is not a
    // character ends the run; `Ctrl+E` is the smallest such thing, and it
    // only asserts what is already true — the caret is at the end of the line.
    terminal
      ..textInput(trimmed)
      ..textInput(kEndOfLineKey)
      ..textInput('\r');
    return true;
  }

  /// Answers an agent's on-screen prompt by pressing [keys] in its terminal.
  ///
  /// Separate from [sendTo] rather than a special case of it, because the two
  /// are different acts. [sendTo] delivers a *message*: it trims, refuses empty
  /// input and appends a carriage return to submit it. An answer is a
  /// **keystroke** — `\r`, `\x1b` — where trimming would erase the whole
  /// payload and an appended return would press a second key nobody asked for.
  ///
  /// [keys] must come from the agent's own [AgentApprovalRules]. Nothing here
  /// invents a binding: this method presses what it is given, and the registry
  /// is what decides whether there is anything to press.
  ///
  /// Returns false when the session has no live pane, so the caller can say the
  /// answer did not land instead of assuming it did.
  ///
  /// **This is where an approval reaches the decision record**, and it is the
  /// only place both answering paths meet: the approval card presses these
  /// keys and so does `session_answer`. Recording here means the packet carries
  /// what the user allowed however they allowed it, rather than only what came
  /// through the bridge.
  ///
  /// [decidedBy] names who answered — the user by default, since the card is
  /// the ordinary route; `session_answer` passes the agent that called it.
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
  /// keystroke is one the agent itself named.
  ///
  /// **A table lookup, not an interpretation.** [keys] is matched against the
  /// agent's own [AgentApprovalRules] — the same table the card read to draw
  /// the button — so what is recorded is the agent's own words for what that
  /// key does. Keys that match neither answer record *nothing*: this method
  /// also carries whatever an agent's prompt was answered with by some other
  /// route, and guessing at what an unrecognised keystroke authorised is
  /// exactly the inference the record must never contain.
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
