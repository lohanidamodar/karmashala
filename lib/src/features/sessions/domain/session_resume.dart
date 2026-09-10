import 'package:agent_cli/descriptors.dart';
import 'session_launch.dart';

/// What "open this conversation again" should actually do.
///
/// Resume is not a read: the CLI takes a **writer** on the conversation, and
/// the agents disagree about whether a second one is allowed
/// (`AgentLaunchSpec.allowsConcurrentResume`). Naming the three answers is what
/// stops every call site inventing its own.
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
/// A pure function rather than a method on a session: a native session, an
/// imported one and an MCP `open_session` must come out the same way.
///
/// Order matters. [weHostItLive] wins wherever a caller *can* reattach, because
/// reattaching is instant, keeps the scrollback and cannot fail. [canReattach]
/// is false when the conversation is handed to a terminal we do not own, so the
/// agent's capability decides — a second Windows Terminal on a live Claude Code
/// conversation is allowed, the same on Codex is not. [allowsConcurrentResume]
/// defaults to false, and [heldByAnotherProcess] is only ever a refusal seen on
/// the agent's own screen.
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

/// What we can honestly say about where a session's process is.
///
/// Separate facts rather than one confident "active" flag, because they are not
/// equally strong: [hostedLive], [refusedResume] and [conversationMissing] are
/// **certain**, while [external] only records where it was *started* — a window
/// we launched an hour ago may have closed since — so it earns a note, never a
/// claim.
///
/// Deliberately no process-handle probing or lock-file inspection: those are
/// platform-specific, fragile, and reverse-engineer another tool's internals to
/// answer a question the persisted record already answers well enough.
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

  /// An agent was asked to resume it and answered that it has no record of the
  /// conversation, and we saw *that* on the pane's own screen.
  ///
  /// **Certain**, like [refusedResume]: the agent's own words about its own
  /// store — see `AgentMissingConversationRules`.
  final bool conversationMissing;

  /// The agent refused a **command-line value we chose for it** and exited
  /// before starting, and we read the refusal off the pane. Null when it said
  /// no such thing.
  ///
  /// The odd one out among the certain facts: this is a fact about Karmashala
  /// being wrong. Modes are declared from the newest CLI that has been read,
  /// but mode support belongs to the *installation*, so an older or newer Codex
  /// gets a flag it will not take. See `AgentRejectedValueRules`.
  final RejectedValue? rejectedValue;

  /// When the newest evidence about this session was **produced** — not when we
  /// last looked; today the modification time of the agent's own transcript,
  /// the only timestamp that means anything once our pane has gone. Null is a
  /// real answer: an age we cannot compute is never rendered as "0m".
  final DateTime? lastSeen;

  /// Whether a second process is *known* to hold the conversation — only the
  /// agent's own refusal counts. [conversationMissing] is the opposite claim,
  /// and [external] would put a confidently wrong badge on every finished
  /// external session.
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

/// A coarse, deliberately unexciting rendering of an age. Rounded down and
/// capped at days: the number says how much to trust the claim beside it, and
/// counting seconds would make a static row look live.
String describeAge(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}

/// The plain-words refusal shown instead of the agent's own JSON-RPC error.
/// The user does not need to know what `-32600` is; they need to know the
/// conversation is open somewhere else, why that stops us, and what to do.
String resumeBlockedMessage(String agentName) =>
    '$agentName will not resume a conversation that another process is already '
    'writing to — two writers would corrupt its transcript. Close it wherever '
    'it is open and try again, or start a new session in this repository.';

/// The banner shown on a pane whose agent refused for this reason.
String resumeConflictPaneMessage(String agentName) =>
    'Open somewhere else — $agentName allows one process per conversation';

/// The plain words for a resume of a conversation that was never written.
///
/// A `--session-id` agent gets one of *our* ids at launch and the row records
/// it immediately, as a **promise** about what the conversation will be called.
/// A failed launch, or a session nothing was ever said in, leaves it unkept,
/// and a later resume reaches the user as a pane that flashes an error and
/// exits. So this says three things in order: that there is nothing to resume,
/// why (so it does not read as data loss), and what to do instead.
String resumeMissingConversationMessage(String agentName) =>
    '$agentName has no record of this conversation, so there is nothing to '
    'resume. The session reserved its id when it started but the agent never '
    'wrote a transcript for it — which is what a session nothing was ever said '
    'in looks like, and what a launch that failed leaves behind. No work has '
    'been lost. Start a new session in this repository.';

/// The plain words for a launch the CLI refused while reading its command line.
///
/// The agent's own `error: invalid value …` is accurate and still leaves the
/// reader with an investigation: it names a flag they never typed, for a mode
/// they picked from a list this app drew. So the sentence says which of *their*
/// choices was refused, what this installation has instead, and that the
/// disagreement is between the app's list and their binary. The values are
/// quoted from the CLI's own refusal, which names the whole valid set.
String rejectedValueMessage(RejectedValue rejected) =>
    "This installation of the agent has no '${rejected.value}' for "
    "'${rejected.flag}', so it refused the command line and stopped before "
    'starting. It offers ${rejected.alternativesLabel}. Karmashala lists the '
    'modes it has read off the newest build of each CLI, and this one does not '
    'agree — choose one of the modes above and the session will start. Nothing '
    'was lost: the agent exited before it opened anything.';

/// The same refusal in one sentence, for a session's own notice bar and the log
/// line beside it.
///
/// [rejectedValueMessage] is the tooltip and has room to explain that the app's
/// list and the binary disagree; a notice has room for the fact, so this says
/// only which of their values this build refused and what it has instead,
/// naming the CLI so it reads as a property of that installation.
String rejectedValueNotice(String agentName, RejectedValue rejected) =>
    "This $agentName does not have '${rejected.value}' for "
    "'${rejected.flag}'; it has ${rejected.alternativesLabel}. It refused the "
    'command line and exited before starting.';
