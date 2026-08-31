/// The phone's view of "which project is this session in".
///
/// The desktop already sends its rows in its Explorer's own display order —
/// pinned first, then projects and sessions exactly as the pane shows them —
/// so grouping here is a **partition, never a sort**. Re-ordering was the bug
/// the user reported twice; this file is the one place that could reintroduce
/// it, and it deliberately cannot: it walks the host's list once and appends.
library;

import '../../explorer/application/session_diff_stat.dart';
import '../client/companion_gateway.dart';

/// One project, with the host's rows for it in the host's own order.
class CompanionProjectGroup {
  const CompanionProjectGroup({required this.key, required this.sessions});

  /// [CompanionSessionSummary.projectKey] — the repository's real identity
  /// when the host sent one, its display name otherwise.
  final String key;

  /// Never empty, and never re-ordered.
  final List<CompanionSessionSummary> sessions;

  String get name => sessions.first.projectName;

  /// The folder on the host, or '' when the host is too old to send one.
  String get path => sessions.first.projectPath ?? '';

  /// Sessions the host says are waiting on the user.
  int get attentionCount => sessions.where((s) => s.attention != null).length;

  /// Sessions mid-turn.
  int get runningCount => sessions
      .where((s) => s.status == CompanionSessionStatus.working)
      .length;

  /// True when the host says any of this project's sessions has lost its
  /// folder — a project you cannot open is worth knowing before you tap it.
  bool get folderMissing => sessions.any((s) => s.folderMissing);

  /// What the shared [ProjectCard] draws on its right-hand side.
  ///
  /// `changedFiles` is deliberately null: the phone has no git of its own and
  /// the protocol carries no count, and inventing "0 changed" would be a claim
  /// the desktop never made.
  ProjectSummary get summary => ProjectSummary(
    sessions: sessions.length,
    running: runningCount,
    needsAttention: attentionCount,
  );
}

/// Partitions [sessions] by project, preserving the host's order both inside a
/// group and across groups.
///
/// A project takes its position from its FIRST session in the host's list, so
/// a `session.changed` that arrives for an existing project lands beside its
/// own siblings instead of on the end. (Dart's map literal is insertion
/// ordered; that is the whole mechanism, and it is load-bearing.)
List<CompanionProjectGroup> groupByProject(
  List<CompanionSessionSummary> sessions,
) {
  final byKey = <String, List<CompanionSessionSummary>>{};
  for (final session in sessions) {
    (byKey[session.projectKey] ??= <CompanionSessionSummary>[]).add(session);
  }
  return [
    for (final entry in byKey.entries)
      CompanionProjectGroup(
        key: entry.key,
        sessions: List.unmodifiable(entry.value),
      ),
  ];
}
