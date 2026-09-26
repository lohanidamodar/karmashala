import 'record_json.dart';
import 'session_ending.dart';

/// A session ended and left something behind: a **durable note the environment
/// is offering back**, written only from typed facts, and never an instruction.
/// It never starts an agent — `FollowUpService` has no path to a launcher.
enum FollowUpReason {
  /// The session stopped in error — the one that matters most in a workspace
  /// with twenty agents: a crash at 14:32 is otherwise silent by 14:33.
  endedInFailure('Ended in error'),

  /// A verification run this session started reached a verdict that was not a
  /// pass.
  verificationNotPassed('Verified, and it did not pass'),

  /// A verification run this session started never reached a verdict. Once the
  /// session has ended, `isOpen` can only mean abandoned.
  verificationAbandoned('Left a check unfinished'),

  /// This session had already ended when follow-ups arrived. Written only by the
  /// v25 migration, already closed, so a workspace's history is not re-raised.
  predatesTheFeature('Ended before follow-ups existed'),

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

/// How an open follow-up stopped being open. Recorded rather than discarded:
/// "why is this not in my list any more?" should have an answer.
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

/// How many open follow-ups are ever handed to the inbox at once. Bounded at
/// the source: an evicted one would be re-filed by the next sync.
const int kOpenFollowUpCap = 200;

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

  /// The session that left this. A plain column and **not** a foreign key: a
  /// deleted session is a state the reader resolves, not a constraint violation.
  final String sessionId;

  final FollowUpReason reason;

  /// How the session ended, kept beside [reason] rather than folded into it.
  /// Two different endings can raise the same reason, and which one it was is
  /// the difference between "it crashed" and "you stopped it" to a reader.
  final SessionEnding ending;

  /// The source's **own words** for what was left, verbatim, or null for "not
  /// recorded". Nothing is ever synthesised to fill it.
  final String? summary;

  final DateTime raisedAt;

  final DateTime? resolvedAt;
  final FollowUpResolution? resolution;

  bool get isOpen => resolvedAt == null;

  /// `'<sessionId>/<ending>'` — the mark that stops one ending being raised
  /// twice, open or resolved.
  String get endingMark => '$sessionId/${ending.name}';

  FollowUp copyWith({
    int? id,
    DateTime? resolvedAt,
    FollowUpResolution? resolution,
  }) => FollowUp(
    id: id ?? this.id,
    sessionId: sessionId,
    reason: reason,
    ending: ending,
    summary: summary,
    raisedAt: raisedAt,
    resolvedAt: resolvedAt ?? this.resolvedAt,
    resolution: resolution ?? this.resolution,
  );

  Map<String, Object?> toJson() => {
    'id': ?id,
    'sessionId': sessionId,
    'reason': reason.name,
    'ending': ending.name,
    'summary': ?summary,
    'raisedAt': jsonDate(raisedAt),
    if (resolvedAt case final at?) 'resolvedAt': jsonDate(at),
    'resolution': ?resolution?.name,
  };

  static FollowUp fromJson(Map<String, Object?> json) => FollowUp(
    id: jsonOptionalInt(json, 'id'),
    sessionId: jsonString(json, 'sessionId'),
    reason: FollowUpReason.fromName(jsonOptionalString(json, 'reason')),
    ending: SessionEnding.fromName(jsonOptionalString(json, 'ending')),
    summary: jsonOptionalString(json, 'summary'),
    raisedAt: jsonDateOf(json, 'raisedAt'),
    resolvedAt: jsonOptionalDateOf(json, 'resolvedAt'),
    resolution: FollowUpResolution.fromName(
      jsonOptionalString(json, 'resolution'),
    ),
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

/// The open follow-ups among [all], newest first, at most [limit] — a work
/// queue, so the thing that just broke is the thing still in the user's head.
/// The table's `ORDER BY raised_at DESC, id DESC`.
List<FollowUp> openFollowUps(
  Iterable<FollowUp> all, {
  int limit = kOpenFollowUpCap,
}) {
  final open = [
    for (final followUp in all)
      if (followUp.isOpen) followUp,
  ]..sort(compareFollowUpsNewestFirst);
  return open.length > limit ? open.sublist(0, limit) : open;
}

int compareFollowUpsNewestFirst(FollowUp a, FollowUp b) {
  final byTime = b.raisedAt.compareTo(a.raisedAt);
  return byTime != 0 ? byTime : (b.id ?? 0).compareTo(a.id ?? 0);
}
