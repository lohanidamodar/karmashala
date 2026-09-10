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

/// **When a session was last active, and what says so** — one definition, so
/// two lists cannot disagree. [at] is when the reading was *produced*.
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

/// The newest of the readings the app holds for one session. Pure, never asking
/// a clock; [createdAt] is not a reading and is only the tie-break.
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
/// nothing — so a silent source contributes no timestamp, not "now".
DateTime? agentEvidenceAt(AgentStatusReport? report) =>
    report == null || report.source == AgentStatusSource.none
    ? null
    : report.evidenceAt;

/// One session as the ordering sees it.
typedef SessionActivityOrder = ({
  SessionLastActive lastActive,
  DateTime createdAt,
});

/// **Most recently active first**, `createdAt` breaking ties. Unknown sorts
/// last, not oldest: no reading is not "idle since the epoch".
int compareByLastActive(SessionActivityOrder a, SessionActivityOrder b) {
  final aAt = a.lastActive.at;
  final bAt = b.lastActive.at;
  if (aAt == null && bAt != null) return 1;
  if (aAt != null && bAt == null) return -1;
  if (aAt != null && bAt != null && aAt != bAt) return bAt.compareTo(aAt);
  return b.createdAt.compareTo(a.createdAt);
}
