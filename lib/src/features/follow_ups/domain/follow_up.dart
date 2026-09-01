import 'session_ending.dart';

/// A session ended and left something behind.
///
/// ## What this is, and what it deliberately is not
///
/// A follow-up is a **durable note that the environment noticed something and
/// is offering it back** — never an instruction it carries out. Karmashala runs
/// many agents at once; today a session ends and the only trace is an attention
/// inbox entry that retires the instant you glance at the session. What the
/// session concluded, and whether anything ever checked it, is then something
/// the user has to remember to go and look for.
///
/// It completes the **decision record** rather than paralleling it. That record
/// answers *what was decided*; this answers *what was left*. Both obey the same
/// two rules, and they are copied here on purpose because they are the whole
/// reason either is trustworthy:
///
/// * **Written only from explicit, structured facts.** A row exists because a
///   session's status said it failed, or because a verification run this
///   session started carries a typed verdict. Nothing here reads a transcript,
///   a terminal buffer or an agent's prose and decides what it must have meant.
/// * **A missing follow-up reads as "nothing was noticed"** — never as "nothing
///   was left". An empty list is not evidence about a session.
///
/// ## The one thing it must never do
///
/// It never starts an agent. Not on a rule, not on a schedule, not because the
/// evidence looked conclusive. Every follow-up ends at an offer the user takes
/// themselves, and `FollowUpService` has no path to a launcher at all — see the
/// test that asserts exactly that.
enum FollowUpReason {
  /// The session stopped in error.
  ///
  /// The one that matters most in a workspace with twenty agents in it: a
  /// crash at 14:32 that nobody was looking at is, today, silent by 14:33.
  endedInFailure('Ended in error'),

  /// A verification run this session started reached a verdict that was not a
  /// pass.
  verificationNotPassed('Verified, and it did not pass'),

  /// A verification run this session started never reached a verdict.
  ///
  /// `VerificationRun.isOpen` means "being recorded right now, **or**
  /// abandoned". Once the session that owned it has ended, only the second
  /// reading is left.
  verificationAbandoned('Left a check unfinished'),

  /// A reason this build does not know. Never written, only read.
  unrecognised('Left something this build cannot describe');

  const FollowUpReason(this.label);

  /// Plain words for a reader — the inbox row's heading.
  final String label;

  static FollowUpReason fromName(String? name) => values.firstWhere(
    (reason) => reason.name == name,
    orElse: () => FollowUpReason.unrecognised,
  );
}

/// How an open follow-up stopped being open.
///
/// Recorded rather than discarded, for the same reason
/// `NotificationSuppression` records why a toast was held back: "why is this
/// not in my list any more?" should have an answer.
enum FollowUpResolution {
  /// The user dismissed it.
  dismissed,

  /// The work moved on — the session acquired a handoff or a fork after this
  /// was raised, so the thing being offered has already been taken.
  carriedForward,

  /// The session itself is gone, so there is nothing left to open.
  sessionGone,

  /// A resolution this build does not know. Never written, only read.
  unrecognised;

  static FollowUpResolution? fromName(String? name) {
    if (name == null) return null;
    return values.firstWhere(
      (resolution) => resolution.name == name,
      orElse: () => FollowUpResolution.unrecognised,
    );
  }
}

/// One thing a session left behind, as it was noticed.
class FollowUp {
  const FollowUp({
    required this.sessionId,
    required this.reason,
    required this.ending,
    required this.raisedAt,
    this.id,
    this.summary,
    this.resolvedAt,
    this.resolution,
  });

  /// Database rowid; `null` for one not yet raised.
  final int? id;

  /// The session that left this. A plain column and **not** a foreign key, the
  /// same choice `VerificationRun.sessionId` makes: a notice about a session
  /// must not be able to take that session's row down with it, and a session
  /// deleted out from under a follow-up is a state the reader resolves
  /// (`FollowUpResolution.sessionGone`) rather than a constraint violation.
  final String sessionId;

  final FollowUpReason reason;

  /// How the session ended, kept beside [reason] rather than folded into it.
  /// Two different endings can raise the same reason, and which one it was is
  /// the difference between "it crashed" and "you stopped it" to a reader.
  final SessionEnding ending;

  /// The source's **own words** for what was left, when the source had any —
  /// a verification run's title and stated reason, verbatim.
  ///
  /// Null is "not recorded" and renders as that. Nothing is ever synthesised to
  /// fill it: a sentence the app made up would be indistinguishable, to the
  /// reader who most needs it, from one an agent actually wrote.
  final String? summary;

  final DateTime raisedAt;

  final DateTime? resolvedAt;
  final FollowUpResolution? resolution;

  bool get isOpen => resolvedAt == null;

  FollowUp copyWith({int? id}) => FollowUp(
    id: id ?? this.id,
    sessionId: sessionId,
    reason: reason,
    ending: ending,
    summary: summary,
    raisedAt: raisedAt,
    resolvedAt: resolvedAt,
    resolution: resolution,
  );

  @override
  bool operator ==(Object other) =>
      other is FollowUp &&
      other.id == id &&
      other.sessionId == sessionId &&
      other.reason == reason &&
      other.ending == ending &&
      other.summary == summary &&
      other.raisedAt == raisedAt &&
      other.resolvedAt == resolvedAt &&
      other.resolution == resolution;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    reason,
    ending,
    summary,
    raisedAt,
    resolvedAt,
    resolution,
  );

  @override
  String toString() =>
      'FollowUp($id, $sessionId, ${reason.name}, open: $isOpen)';
}
