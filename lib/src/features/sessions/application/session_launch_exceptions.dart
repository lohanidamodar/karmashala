/// The four ways a launch says no, and the words each one says it in.
///
/// A library of its own rather than a `part`, because none of them touches the
/// launcher's state: each is a value carrying a sentence, and the sentence is
/// the contract. Separate types so the MCP surface and fan-out can fail the
/// caller's *turn* with the explanation rather than report a generic error.
library;

import '../domain/session_depth.dart';
import '../domain/session_resume.dart';

/// Raised when the recursion cap or the cycle guard refuses a launch. Its own
/// type so the MCP surface can fail the caller's *turn* with the explanation.
class SessionDepthRefused implements Exception {
  const SessionDepthRefused(this.depth);
  final SessionDepth depth;

  @override
  String toString() => depth.refusal;
}

/// Raised when a launch was asked to carry an opening message the agent's
/// command line cannot take — its own type so the MCP surface and fan-out fail
/// the caller rather than starting an agent that never hears the instruction
/// and reporting success.
class SessionLaunchRefused implements Exception {
  const SessionLaunchRefused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Raised when a resume would start a **second** agent on a conversation whose
/// first one is still running, **and that agent will not share it**. Codex
/// answers `thread/resume failed: … already has an active writer (-32600)`,
/// which would otherwise reach the user as raw JSON-RPC during TUI bootstrap;
/// [toString] is the plain-words version.
///
/// **Only thrown for an agent that forbids it** — firing for every agent
/// refused the case Claude Code supports, a second terminal listening to one
/// conversation. Surfaces that can reopen the running view do so instead and
/// never get here.
class SessionAlreadyRunning implements Exception {
  const SessionAlreadyRunning({
    required this.agentName,
    this.sessionId,
    this.title,
  });

  /// The session already running it — the one to reveal. Null when the holder
  /// is a process we do not own, which we only ever learn from the agent's own
  /// refusal.
  final String? sessionId;

  /// That session's title, when it is one of ours.
  final String? title;

  /// The agent's display name, so the refusal says *who* is refusing — which is
  /// what makes it read as a property of this CLI, not of Karmashala.
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
/// held — the other side of `sessionIdAssignment`. Passing Claude Code our id
/// as `--session-id` records it on the row **before** the CLI has written a
/// byte, so a launch that failed leaves a row claiming a conversation that does
/// not exist; resuming it printed `No conversation found with session ID: …` on
/// the user's screen while the app said nothing.
///
/// **Only thrown on certain knowledge**: the store must have been read to the
/// end without the conversation in it, and a store we could not reach answers
/// `unknown` so the resume proceeds exactly as it did before.
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
