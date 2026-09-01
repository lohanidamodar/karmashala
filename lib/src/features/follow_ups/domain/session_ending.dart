import '../../agents/domain/agent_status.dart';
import '../../sessions/domain/session_status.dart';

/// How a session stopped — which is **not one event**, and the difference is
/// the whole feature.
///
/// `detach_policy.dart` makes the same argument one layer down: a clean exit
/// and a failure are different facts about a process, and a rule that treats
/// them alike either kills work somebody wanted or keeps rubbish forever. Here
/// the cost of confusing them is a notice: read a handoff as a crash and the
/// app nags about work already carried forward; read a crash as a clean finish
/// and the one thing nobody noticed stays unnoticed.
///
/// Five values, because there are five answers and not four: **losing sight of
/// a session is its own state**, and it is the one this file exists to keep out
/// of the other four. `NotificationSuppression.lostTrack` already refuses to
/// call it news for exactly this reason.
enum SessionEnding {
  /// The agent's own run ended without an error.
  completed,

  /// The agent stopped in error, or its launch never got off the ground.
  failed,

  /// The user stopped it.
  cancelled,

  /// The work moved to another session — a handoff or a fork.
  handedOff,

  /// Nothing can tell us what this session is doing any more.
  ///
  /// Deliberately **not** an ending, and named so the code can say that out
  /// loud rather than leaving a silent gap in a `switch`. A pane behind a
  /// screen lock, a transcript on a network share that went away and an agent
  /// that genuinely exited all look identical from here, and the app's standing
  /// rule is that what it cannot know for certain it says in words rather than
  /// guessing at.
  lostTrack,

  /// An ending this build does not know — a row from a newer schema, or a
  /// hand-edited database.
  ///
  /// Never written, only read, exactly like `DecisionKind.unrecognised`: a
  /// wrong word over a real ending is worse than an admission that the word
  /// could not be read.
  unrecognised;

  /// Plain words for a reader.
  String get label => switch (this) {
    SessionEnding.completed => 'finished',
    SessionEnding.failed => 'stopped in error',
    SessionEnding.cancelled => 'was stopped by you',
    SessionEnding.handedOff => 'was handed on',
    SessionEnding.lostTrack => 'went out of sight',
    SessionEnding.unrecognised => 'ended in a way this build cannot describe',
  };

  static SessionEnding fromName(String? name) => values.firstWhere(
    (ending) => ending.name == name,
    orElse: () => SessionEnding.unrecognised,
  );
}

/// The ending a session's own row claims, or null while it is still live.
///
/// The durable half of the signal: a row that says `failed` still says it
/// tomorrow, which is what lets a follow-up be noticed after a restart rather
/// than only in the instant the session died.
///
/// [SessionStatus.idle] is **live**, not ended. It is the state an agent sits
/// in between turns.
SessionEnding? endingOfStatus(SessionStatus status) => switch (status) {
  SessionStatus.completed => SessionEnding.completed,
  SessionStatus.failed => SessionEnding.failed,
  SessionStatus.cancelled => SessionEnding.cancelled,
  SessionStatus.created || SessionStatus.running || SessionStatus.idle => null,
};

/// The ending an observed status change amounts to, or null when it is not an
/// ending at all.
///
/// The live half of the signal, and it is deliberately almost entirely null:
///
/// * **A first observation says nothing.** `from` is null for every live
///   session on app start, and `AgentStatusTransition` already documents why
///   that is not evidence a change just happened. Reading it as a crash would
///   raise a follow-up on launch for every session that broke last week.
/// * **A turn ending is not a session ending.** `working → idle` is what the
///   attention inbox already calls "finished", and it happens many times in one
///   session. A follow-up per turn is a log, not a work queue.
/// * **`unknown` is [SessionEnding.lostTrack]**, which the policy answers with
///   silence. It is named rather than dropped so the refusal is a decision in
///   the code instead of a case nobody wrote.
SessionEnding? endingOfTransition({
  required AgentActivityStatus? from,
  required AgentActivityStatus to,
}) {
  if (from == null || from == to) return null;
  return switch (to) {
    AgentActivityStatus.failed => SessionEnding.failed,
    AgentActivityStatus.unknown => SessionEnding.lostTrack,
    AgentActivityStatus.idle ||
    AgentActivityStatus.working ||
    AgentActivityStatus.awaitingApproval => null,
  };
}
