import '../../agents/domain/agent_status.dart';
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
/// Deliberately a pure function of four booleans rather than a method on a
/// session: the same decision is made for a native session, an imported CLI
/// session and an MCP `open_session` call, and it must come out the same way in
/// all three.
///
/// Order matters.
///
/// * [weHostItLive] wins over everything a caller that *can* reattach could do,
///   including for an agent that would have permitted a second process, because
///   reattaching is strictly better than spawning: it is instant, it keeps the
///   scrollback, and it cannot fail.
/// * [canReattach] is false for a caller handing the conversation somewhere we
///   do not own — an external terminal window. Reopening our own tab is not what
///   was asked for there, so a pane of ours becomes just another holder and the
///   agent's capability decides. This is the case the owner cares about: a
///   second Windows Terminal on a live Claude Code conversation is allowed,
///   the same thing on Codex is not.
/// * [allowsConcurrentResume] then settles it. It is false by default for
///   agents nobody has tested, so an unknown agent is treated as single-writer.
/// * [heldByAnotherProcess] is only ever *certain* knowledge — an agent's own
///   refusal, seen on its screen. It is never inferred from a record.
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
/// Separate facts rather than one confident "active" flag, because they
/// are not equally strong and the UI must not present them as if they were:
///
/// * [hostedLive] is **certain** — we own the process and can see it.
/// * [refusedResume] is **certain** — the agent itself told us another process
///   holds the conversation. It is the only proof we ever get about a process
///   we do not own.
/// * [conversationMissing] is **certain** — the agent itself told us it has no
///   record of the conversation at all.
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
  /// **Certain**, like [refusedResume], and for the same reason: it is the
  /// agent's own words about its own store. It is the honest end of a resume
  /// the store probe could not predict — see `AgentMissingConversationRules`.
  final bool conversationMissing;

  /// The agent refused a **command-line value we chose for it** and exited
  /// before starting, and we read the refusal off the pane. Null when it said
  /// no such thing.
  ///
  /// **Certain**, like the two above, and the odd one out among them: those are
  /// facts about the user's conversations, this is a fact about Karmashala
  /// being wrong. A permission mode is declared from the newest CLI that has
  /// been read, and mode support belongs to the *installation* — so a machine
  /// whose Codex is older or newer than that one gets a flag it will not take,
  /// and used to get a pane that flashed the raw `error: invalid value …` and
  /// died. See `AgentRejectedValueRules`.
  final RejectedValue? rejectedValue;

  /// When the newest evidence about this session was **produced** — not when we
  /// last looked. Today that is the modification time of the agent's own
  /// transcript, which is the only timestamp that means anything once our pane
  /// has gone.
  ///
  /// Null when we have no such evidence at all, which is a real answer and is
  /// rendered as one: an age we cannot compute is never rendered as "0m".
  final DateTime? lastSeen;

  /// Whether a second process is *known* to hold the conversation.
  ///
  /// [conversationMissing] deliberately does not count here: an agent that has
  /// no record of a conversation is telling us the opposite of "somebody else
  /// is writing to it", and folding the two together would block a resume that
  /// should instead be explained.
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
    // Ahead of the two resume answers because it happened earlier than either
    // could: the CLI exited while reading its command line, so it never got as
    // far as having an opinion about the conversation.
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

  /// The "last seen" clause, aged against [now], or null when we have no
  /// evidence to age.
  ///
  /// Never rendered for [hostedLive]: we can see that process, so "running
  /// here" is a stronger and more honest thing to say than a timestamp.
  String? lastSeenLabel(DateTime now) {
    if (hostedLive) return null;
    final at = lastSeen;
    return at == null ? null : 'last seen ${describeAge(now.difference(at))}';
  }
}

/// A coarse, deliberately unexciting rendering of an age.
///
/// Rounded down and capped at days, because the point of the number is to tell
/// the user how much to trust the claim beside it, not to be a clock. "just now"
/// covers the first minute rather than counting seconds, which would make a
/// static row look live.
String describeAge(Duration age) {
  if (age.isNegative || age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
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

/// The plain words for a resume of a conversation that was never written.
///
/// A session whose agent takes a `--session-id` gets one of *our* ids at
/// launch, and the row records it immediately. That id is a **promise**: it
/// says what the conversation will be called once the CLI writes it. A launch
/// that failed, or a session nothing was ever said in, leaves the promise
/// unkept — the row names a conversation that does not exist, and the agent
/// answers a later resume with its own version of "no conversation found",
/// which reaches the user as a pane that flashes an error and exits.
///
/// Three things this has to say, in this order: that there is nothing to
/// resume, *why* there is nothing (so it does not read as data loss), and what
/// to do instead.
String resumeMissingConversationMessage(String agentName) =>
    '$agentName has no record of this conversation, so there is nothing to '
    'resume. The session reserved its id when it started but the agent never '
    'wrote a transcript for it — which is what a session nothing was ever said '
    'in looks like, and what a launch that failed leaves behind. No work has '
    'been lost. Start a new session in this repository.';

/// The plain words for a launch the CLI refused while reading its command line.
///
/// Shown instead of the agent's own `error: invalid value 'untrusted' for
/// '--ask-for-approval &lt;APPROVAL_POLICY&gt;'`, which is accurate, complete
/// and still leaves the reader with an investigation: it names a flag they
/// never typed, for a mode they picked from a list this app drew.
///
/// So the sentence says the three things that turn it back into a decision:
/// which of *their* choices was refused, what this installation has instead,
/// and that the disagreement is between the app's list and their binary rather
/// than anything they did. The values are quoted from the CLI's own refusal —
/// it names the whole valid set, which is what makes a readable message
/// possible at all.
String rejectedValueMessage(RejectedValue rejected) =>
    "This installation of the agent has no '${rejected.value}' for "
    "'${rejected.flag}', so it refused the command line and stopped before "
    'starting. It offers ${rejected.alternativesLabel}. Karmashala lists the '
    'modes it has read off the newest build of each CLI, and this one does not '
    'agree — choose one of the modes above and the session will start. Nothing '
    'was lost: the agent exited before it opened anything.';

/// The same refusal in one sentence, for a session's own notice bar and for the
/// log line beside it.
///
/// [rejectedValueMessage] is the tooltip: it has room to explain that the app's
/// list and the binary disagree. A notice has room for the fact, so this says
/// only the two things nothing else on screen can tell the reader — which of
/// their values this build refused, and what it has instead — and names the CLI
/// so the disagreement reads as a property of *that* installation.
String rejectedValueNotice(String agentName, RejectedValue rejected) =>
    "This $agentName does not have '${rejected.value}' for "
    "'${rejected.flag}'; it has ${rejected.alternativesLabel}. It refused the "
    'command line and exited before starting.';
