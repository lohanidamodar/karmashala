import 'session_launch.dart';

/// What "open this conversation again" should actually do.
///
/// Resume is not a read. The CLI takes a **writer** on the conversation, so
/// "resume it again" is a request to start a second process against a record
/// something else may be holding — and the agents disagree about whether that is
/// allowed (`AgentLaunchSpec.allowsConcurrentResume`). Naming the three answers
/// is what stops every call site inventing its own.
enum ResumeAction {
  /// A pane of ours is already running it. Bring that pane back: nothing is
  /// spawned, nothing is lost, and no agent can object.
  reattach,

  /// Start the agent on the existing conversation.
  resume,

  /// Another process holds it and this agent will not share. Say so; do not
  /// spawn something that will exit with an error on the user's screen.
  blocked,
}

/// Chooses between them.
///
/// Deliberately a pure function of three booleans rather than a method on a
/// session: the same decision is made for a native session, an imported CLI
/// session and an MCP `open_session` call, and it must come out the same way in
/// all three.
///
/// Order matters. [weHostItLive] wins over everything, including an agent that
/// would have permitted a second process, because reattaching is strictly
/// better than spawning: it is instant, it keeps the scrollback, and it cannot
/// fail.
ResumeAction resumeActionFor({
  required bool weHostItLive,
  required bool allowsConcurrentResume,
  required bool heldByAnotherProcess,
}) {
  if (weHostItLive) return ResumeAction.reattach;
  if (allowsConcurrentResume) return ResumeAction.resume;
  return heldByAnotherProcess ? ResumeAction.blocked : ResumeAction.resume;
}

/// What we can honestly say about where a session's process is.
///
/// Three separate facts rather than one confident "active" flag, because they
/// are not equally strong and the UI must not present them as if they were:
///
/// * [hostedLive] is **certain** — we own the process and can see it.
/// * [refusedResume] is **certain** — the agent itself told us another process
///   holds the conversation. It is the only proof we ever get about a process
///   we do not own.
/// * [external] is only a record of **where it was started**. A terminal window
///   we launched an hour ago may have been closed since, and we have no way to
///   know. It earns a note, never a claim.
///
/// There is deliberately no process-handle probing or lock-file inspection here.
/// Those are platform-specific, fragile, and reverse-engineer another tool's
/// internals to answer a question the persisted record already answers well
/// enough.
class SessionWhereabouts {
  const SessionWhereabouts({
    this.hostedLive = false,
    this.external = false,
    this.refusedResume = false,
  });

  /// A pane of ours is running it right now.
  final bool hostedLive;

  /// It was launched into a terminal emulator we do not own
  /// ([SessionSurface.external]).
  final bool external;

  /// An agent refused to resume it because another process holds the
  /// conversation, and we saw the refusal on the pane's own screen.
  final bool refusedResume;

  /// Whether a second process is *known* to hold the conversation.
  ///
  /// Only the agent's own refusal counts. [external] deliberately does not:
  /// treating "we launched a window once" as "it is running now" would put a
  /// confidently wrong badge on every finished external session, and a user who
  /// catches an indicator lying once stops reading it.
  bool get knownHeldElsewhere => refusedResume;

  /// One clause for a session row's subtitle, or null when there is nothing
  /// worth saying. Phrased as what we know, not as what we suspect.
  String? get note {
    if (hostedLive) return 'running here';
    if (refusedResume) return 'open in another process';
    if (external) return 'external terminal';
    return null;
  }

  /// The longer form, for a tooltip.
  String? get explanation {
    if (hostedLive) return 'Running in a terminal pane in this window.';
    if (refusedResume) {
      return 'The agent refused to resume this conversation because another '
          'process is already writing to it.';
    }
    if (external) {
      return 'Started in a terminal window Chitragupta does not own, so we '
          'cannot see whether it is still running.';
    }
    return null;
  }
}

/// The plain-words refusal shown instead of the agent's own JSON-RPC error.
///
/// The user does not need to know what `-32600` is; they need to know that the
/// conversation is open somewhere else, why that stops us, and what they can do
/// instead.
String resumeBlockedMessage(String agentName) =>
    '$agentName will not resume a conversation that another process is already '
    'writing to — two writers would corrupt its transcript. Close it wherever '
    'it is open and try again, or start a new session in this repository.';

/// The banner shown on a pane whose agent refused for this reason.
String resumeConflictPaneMessage(String agentName) =>
    'Open somewhere else — $agentName allows one process per conversation';
