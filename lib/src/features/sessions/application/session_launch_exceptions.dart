/// The four ways a launch says no, and the words each one says it in.
///
/// A library of its own rather than a `part`, because none of them touches
/// the launcher's state: each is a value carrying a sentence, and the
/// sentence is the contract. They are separate types rather than one
/// `LaunchRefused` with a reason for the same purpose the MCP surface and
/// fan-out both need — failing the caller's *turn* with the explanation,
/// rather than reporting a generic error and starting nothing.
///
/// Re-exported by `session_launcher.dart`, which is where every caller
/// already reaches for them.
library;

import '../domain/session_depth.dart';
import '../domain/session_resume.dart';

/// Raised when the recursion cap or the cycle guard refuses a launch.
///
/// Its own type so the MCP surface can fail the caller's *turn* with the
/// explanation rather than reporting a generic error.
class SessionDepthRefused implements Exception {
  const SessionDepthRefused(this.depth);
  final SessionDepth depth;

  @override
  String toString() => depth.refusal;
}

/// Raised when a launch was asked to carry an opening message that the agent's
/// command line cannot take.
///
/// Its own type for the same reason as [SessionDepthRefused]: the MCP surface
/// and fan-out both need to fail the caller with the explanation, rather than
/// starting an agent that never hears the instruction and reporting success.
class SessionLaunchRefused implements Exception {
  const SessionLaunchRefused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Raised when a resume would start a **second** agent on a conversation whose
/// first one is still running, **and that agent will not share it**.
///
/// Loop 38 separated session lifetime from view lifetime: closing a tab detaches
/// the view and leaves the process running. So "resume this session" stopped
/// meaning "nothing is running it" — and launching anyway hands the agent CLI a
/// transcript it already holds open. Codex refuses that outright:
///
/// ```
/// thread/resume failed: thread <id> already has an active writer (code -32600)
/// ```
///
/// which reaches the user as a raw JSON-RPC failure during TUI bootstrap. That
/// string never reaches the user from here: [toString] is the plain-words
/// version, and it is what the UI shows.
///
/// **Only thrown for an agent that forbids it.** Loop 46 made that conditional:
/// this used to fire for every agent, which refused the case Claude Code
/// actually supports — a second terminal listening to the same conversation.
/// See [AgentLaunchSpec.allowsConcurrentResume] and [resumeActionFor].
///
/// In-app surfaces that *can* reopen the running view do so instead and never
/// get here, so this is thrown where reopening is not what was asked for —
/// handing the session to an external terminal — and by [SessionLauncher.launch]
/// itself, as the backstop no future caller can forget.
class SessionAlreadyRunning implements Exception {
  const SessionAlreadyRunning({
    required this.agentName,
    this.sessionId,
    this.title,
  });

  /// The session already running it — the one to reveal. Null when the holder is
  /// a process we do not own, which we only ever learn from the agent's own
  /// refusal.
  final String? sessionId;

  /// That session's title, when it is one of ours.
  final String? title;

  /// The agent's display name, so the refusal says *who* is refusing. Naming it
  /// is what makes "start a new session instead" read as a property of this CLI
  /// rather than a limitation of Karmashala.
  final String agentName;

  @override
  String toString() {
    final where = title == null
        ? 'That conversation is already open in another process.'
        : '"$title" is already running in Karmashala.';
    return '$where ${resumeBlockedMessage(agentName)}';
  }
}

/// Raised when a resume names a conversation the agent's own store has never
/// held.
///
/// The other side of `sessionIdAssignment`. Passing Claude Code our id as
/// `--session-id` is what lets a row know its conversation without parsing
/// anything, but it also means the row records that id **before** the CLI has
/// written a single byte — so a launch that failed, or a session nothing was
/// ever said in, leaves a row claiming a conversation that does not exist.
/// Nothing distinguished such a row from a real one, and resuming it ran
///
/// ```
/// No conversation found with session ID: 4b13c55e-…
/// [process exited with code 1]
/// ```
///
/// on the user's screen while the app said nothing and went on creating
/// sessions around it.
///
/// **Only thrown on certain knowledge.** The store must have been read to the
/// end without the conversation in it; a store we could not locate or reach
/// answers `unknown` and the resume proceeds exactly as it did before (see
/// `conversationPresenceProvider`).
class SessionConversationMissing implements Exception {
  const SessionConversationMissing({
    required this.agentName,
    required this.conversationId,
    this.sessionId,
    this.title,
  });

  /// The CLI id that names nothing. Included in [toString] because a user whose
  /// store is configured somewhere unusual needs to be able to go and look.
  final String conversationId;

  /// Our row for it, so a caller can reveal or tidy it.
  final String? sessionId;

  /// That row's title, for the message.
  final String? title;

  /// The agent's display name, so the sentence says who has no record.
  final String agentName;

  @override
  String toString() {
    final what = title == null ? 'This session' : '"$title"';
    return '$what cannot be resumed: '
        '${resumeMissingConversationMessage(agentName)} '
        '(conversation id $conversationId)';
  }
}
