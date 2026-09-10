/// The four ways a launch says no, and the words each one says it in —
/// separate types so a caller can fail its own *turn* with the explanation.
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
/// command line cannot take, so no agent starts having been told nothing.
class SessionLaunchRefused implements Exception {
  const SessionLaunchRefused(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Raised when a resume would be a **second** agent on a live conversation and
/// the agent will not share it — Codex answers "already has an active writer".
class SessionAlreadyRunning implements Exception {
  const SessionAlreadyRunning({
    required this.agentName,
    this.sessionId,
    this.title,
  });

  /// The session already running it — the one to reveal. Null when the holder
  /// is a process we do not own, learned only from the agent's own refusal.
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

/// Raised when a resume names a conversation the agent's store has never held:
/// our `--session-id` is on the row before the CLI has written a byte.
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
