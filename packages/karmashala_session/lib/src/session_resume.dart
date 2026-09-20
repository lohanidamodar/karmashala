import 'package:agent_cli/descriptors.dart';
import 'session_launch.dart';

/// What "open this conversation again" should actually do. Resume is not a
/// read: the CLI takes a **writer**, and the agents disagree about a second one.
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

/// Chooses between them. Reattaching wins wherever a caller can; otherwise the
/// agent's `allowsConcurrentResume` decides, and it is false until tested.
ResumeAction resumeActionFor({
  required bool weHostItLive,
  required bool allowsConcurrentResume,
  required bool heldByAnotherProcess,
  bool canReattach = true,
}) {
  if (weHostItLive && canReattach) return ResumeAction.reattach;
  if (allowsConcurrentResume) return ResumeAction.resume;
  if (weHostItLive || heldByAnotherProcess) return ResumeAction.blocked;
  return ResumeAction.resume;
}

/// What we can honestly say about where a session's process is: separate facts,
/// because [external] is only where it *started*. No handle or lock-file probe.
class SessionWhereabouts {
  const SessionWhereabouts({
    this.hostedLive = false,
    this.external = false,
    this.refusedResume = false,
    this.conversationMissing = false,
    this.rejectedValue,
    this.lastSeen,
  });

  /// A pane of ours is running it right now.
  final bool hostedLive;

  /// It was launched into a terminal emulator we do not own
  /// ([SessionSurface.external]).
  final bool external;

  /// An agent refused to resume it because another process holds the
  /// conversation, and we saw the refusal on the pane's own screen.
  final bool refusedResume;

  /// The agent answered that it has no record of the conversation, seen on the
  /// pane's own screen. **Certain**, like [refusedResume] — its own words.
  final bool conversationMissing;

  /// The agent refused a **command-line value we chose for it** and exited
  /// before starting. A fact about Karmashala being wrong, not about the user.
  final RejectedValue? rejectedValue;

  /// When the newest evidence was **produced**, not when we last looked. Null
  /// is a real answer: an age we cannot compute is never rendered as "0m".
  final DateTime? lastSeen;

  /// Whether a second process is *known* to hold the conversation — only the
  /// agent's own refusal counts, never [external], which would badge the dead.
  bool get knownHeldElsewhere => refusedResume;

  /// One clause for a session row's subtitle, or null when there is nothing
  /// worth saying. Phrased as what we know, not as what we suspect.
  String? get note {
    if (hostedLive) return 'running here';
    // Ahead of the two resume answers because it happened earlier than either
    // could: the CLI exited while reading its command line.
    final rejected = rejectedValue;
    if (rejected != null) {
      return "would not start — no '${rejected.value}' in this build";
    }
    if (refusedResume) return 'open in another process';
    if (conversationMissing) return 'no conversation to resume';
    if (external) return 'opened in an external terminal';
    return null;
  }

  /// The longer form, for a tooltip.
  String? get explanation {
    if (hostedLive) return 'Running in a terminal pane in this window.';
    final rejected = rejectedValue;
    if (rejected != null) return rejectedValueMessage(rejected);
    if (refusedResume) {
      return 'The agent refused to resume this conversation because another '
          'process is already writing to it.';
    }
    if (conversationMissing) {
      return 'The agent was asked to resume this conversation and answered '
          'that it has no record of it, so the transcript was never written. '
          'Nothing has been lost; start a new session instead.';
    }
    if (external) {
      return 'Started in a terminal window Karmashala does not own, so we '
          'cannot see whether it is still running.';
    }
    return null;
  }
}

/// A coarse, deliberately unexciting rendering of an age. Counting seconds
/// would make a static row look live.
String describeAge(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}

/// The plain-words refusal shown instead of the agent's own JSON-RPC error: the
/// user needs to know where the conversation is open, not what `-32600` is.
String resumeBlockedMessage(String agentName) =>
    '$agentName will not resume a conversation that another process is already '
    'writing to — two writers would corrupt its transcript. Close it wherever '
    'it is open and try again, or start a new session in this repository.';

/// The banner shown on a pane whose agent refused for this reason.
String resumeConflictPaneMessage(String agentName) =>
    'Open somewhere else — $agentName allows one process per conversation';

/// The plain words for a resume of a conversation that was never written: there
/// is nothing to resume, why that is not data loss, and what to do instead.
String resumeMissingConversationMessage(String agentName) =>
    '$agentName has no record of this conversation, so there is nothing to '
    'resume. The session reserved its id when it started but the agent never '
    'wrote a transcript for it — which is what a session nothing was ever said '
    'in looks like, and what a launch that failed leaves behind. No work has '
    'been lost. Start a new session in this repository.';

/// The plain words for a launch the CLI refused while reading its command line.
/// Names which of *their* choices was refused and what this build has instead.
String rejectedValueMessage(RejectedValue rejected) =>
    "This installation of the agent has no '${rejected.value}' for "
    "'${rejected.flag}', so it refused the command line and stopped before "
    'starting. It offers ${rejected.alternativesLabel}. Karmashala lists the '
    'modes it has read off the newest build of each CLI, and this one does not '
    'agree — choose one of the modes above and the session will start. Nothing '
    'was lost: the agent exited before it opened anything.';

/// The same refusal in one sentence, for a session's own notice bar.
/// [rejectedValueMessage] is the tooltip, with room to explain the mismatch.
String rejectedValueNotice(String agentName, RejectedValue rejected) =>
    "This $agentName does not have '${rejected.value}' for "
    "'${rejected.flag}'; it has ${rejected.alternativesLabel}. It refused the "
    'command line and exited before starting.';
