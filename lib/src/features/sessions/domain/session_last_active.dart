import 'package:agent_cli/descriptors.dart';

import 'session_resume.dart' show describeAge;

/// Where a last-active reading came from.
enum LastActiveSource {
  /// The agent's own newest evidence — the hook it fired, the transcript it
  /// wrote, or the pane it is printing into. See [AgentStatusReport.evidenceAt].
  agent,

  /// The CLI store file a conversation was read out of, by its own mtime. The
  /// coarsest reading that is still the agent's writing.
  store,

  /// Nothing the app holds says when this session was last active.
  none,
}

/// **When a session was last active, and what says so.**
///
/// One definition, shared by every list that orders sessions and every row that
/// draws the age: two lists disagreeing about which session is freshest is the
/// bug this type exists to make impossible.
///
/// [at] is when the reading was **produced**, never when we looked for it.
/// Nothing here polls — the readings are ones the app already holds.
class SessionLastActive {
  const SessionLastActive({required this.at, required this.source});

  /// No reading at all — a first-class answer, not a zero one. Drawn as no age
  /// rather than "just now", and it sorts *after* every session that has one.
  static const unknown = SessionLastActive(
    at: null,
    source: LastActiveSource.none,
  );

  /// When the newest reading was produced, UTC, or null for [unknown].
  final DateTime? at;

  final LastActiveSource source;

  bool get isKnown => at != null;

  /// "active 3m ago", or null when there is no reading to age. [describeAge]'s
  /// wording, so a session's age reads the same as every other age in the app.
  String? label(DateTime now) {
    final at = this.at;
    return at == null ? null : 'active ${describeAge(now.difference(at))}';
  }

  @override
  bool operator ==(Object other) =>
      other is SessionLastActive && other.at == at && other.source == source;

  @override
  int get hashCode => Object.hash(at, source);

  @override
  String toString() => 'SessionLastActive(${at ?? 'unknown'}, ${source.name})';
}

/// The newest of the readings the app holds for one session.
///
/// Pure and deliberately so: handed readings, never asking a clock, so the same
/// inputs order the same way in a test, on the desktop and on the phone.
/// Passing "now" for a session we know nothing about is the confident false
/// statement this refuses.
///
/// [createdAt] is **not** a reading and is not accepted here: folding it in
/// would make a year-old row that has never run look as fresh as its birthday.
/// It is the tie-break in [compareByLastActive] instead.
SessionLastActive newestLastActive({
  DateTime? agentEvidenceAt,
  DateTime? storeModifiedAt,
}) {
  if (agentEvidenceAt == null && storeModifiedAt == null) {
    return SessionLastActive.unknown;
  }
  if (storeModifiedAt == null) {
    return SessionLastActive(
      at: agentEvidenceAt,
      source: LastActiveSource.agent,
    );
  }
  if (agentEvidenceAt == null) {
    return SessionLastActive(
      at: storeModifiedAt,
      source: LastActiveSource.store,
    );
  }
  // A tie goes to the agent: both readings are the same instant, and the finer
  // source is the one worth naming.
  return storeModifiedAt.isAfter(agentEvidenceAt)
      ? SessionLastActive(at: storeModifiedAt, source: LastActiveSource.store)
      : SessionLastActive(at: agentEvidenceAt, source: LastActiveSource.agent);
}

/// The timestamp on a status report, or null when the report is evidence about
/// nothing. The one place that decision is made, so a source that could tell us
/// nothing contributes no timestamp rather than the moment we asked it.
DateTime? agentEvidenceAt(AgentStatusReport? report) =>
    report == null || report.source == AgentStatusSource.none
    ? null
    : report.evidenceAt;

/// One session as the ordering sees it.
typedef SessionActivityOrder = ({
  SessionLastActive lastActive,
  DateTime createdAt,
});

/// **Most recently active first**, with [SessionLastActive.unknown] last and
/// `createdAt` — newest first — breaking every tie. Unknown sorts last rather
/// than oldest: a session we hold no reading for has not been idle since the
/// epoch, and placing it among the stale rows would be a claim we cannot make.
int compareByLastActive(SessionActivityOrder a, SessionActivityOrder b) {
  final aAt = a.lastActive.at;
  final bAt = b.lastActive.at;
  if (aAt == null && bAt != null) return 1;
  if (aAt != null && bAt == null) return -1;
  if (aAt != null && bAt != null && aAt != bAt) return bAt.compareTo(aAt);
  return b.createdAt.compareTo(a.createdAt);
}
