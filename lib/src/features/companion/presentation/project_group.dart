/// The phone's view of "which project is this session in".
///
/// The desktop already sends its rows in its Explorer's own display order —
/// pinned first, then projects and sessions exactly as the pane shows them —
/// so grouping here is a **partition, never a sort**. Re-ordering was the bug
/// the user reported twice; this file is the one place that could reintroduce
/// it, and it deliberately cannot: it walks the host's list once and appends.
library;

import '../../explorer/application/session_diff_stat.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:karmashala_remote/companion.dart';

/// One project, with the host's rows for it in the host's own order.
class CompanionProjectGroup {
  const CompanionProjectGroup({
    required this.key,
    required this.sessions,
    this.project,
    this.fallbackName,
    this.fallbackPath,
    this.fallbackEnvironmentBadge,
  });

  /// [CompanionSessionSummary.projectKey] — the repository's real identity
  /// when the host sent one, its display name otherwise.
  final String key;

  /// Host sessions in host order; metadata-only projects may be empty.
  final List<CompanionSessionSummary> sessions;

  /// Metadata from the desktop project index. It is present even when this
  /// project has no sessions yet.
  final RemoteWorkspaceProject? project;

  /// What this project is called, where it lives and which environment it is
  /// in **when its own rows can no longer say** — carried by [withSessions] so
  /// a group narrowed to nothing is still the project it was.
  ///
  /// Without them, a host too old to send project metadata leaves a filtered
  /// group deriving its name from `sessions.first`, and a filter that matched
  /// none of them renames the user's project to "Project".
  final String? fallbackName;
  final String? fallbackPath;
  final String? fallbackEnvironmentBadge;

  /// The same project holding only [sessions] — what a filter returns.
  CompanionProjectGroup withSessions(List<CompanionSessionSummary> sessions) =>
      CompanionProjectGroup(
        key: key,
        sessions: List.unmodifiable(sessions),
        project: project,
        fallbackName: name,
        fallbackPath: path,
        fallbackEnvironmentBadge: environmentBadge,
      );

  String get name =>
      project?.name ??
      sessions.firstOrNull?.projectName ??
      fallbackName ??
      'Project';

  /// The host's own id for this project, when it sent one — what a start
  /// screen opened from here preselects.
  String? get projectId => project?.projectId ?? sessions.firstOrNull?.projectId;

  /// The folder on the host, or '' when the host is too old to send one.
  String get path =>
      project?.path ??
      sessions.firstOrNull?.projectPath ??
      fallbackPath ??
      '';

  /// Which execution environment this project lives in, formatted for a badge
  /// or tag (e.g. "WSL · Ubuntu", "SSH · build-box"). Null for local host.
  String? get environmentBadge =>
      project?.environmentBadge ??
      (project?.environmentName != null &&
              project!.environmentName != 'Windows' &&
              project!.environmentName != 'macOS' &&
              project!.environmentName != 'Linux'
          ? project!.environmentName
          : null) ??
      sessions.firstOrNull?.environmentBadge ??
      fallbackEnvironmentBadge;

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

/// Joins the host's project metadata with the live session rows. The metadata
/// order is authoritative; session-only rows remain visible for older hosts
/// that cannot answer the project request.
List<CompanionProjectGroup> mergeProjectsAndSessions(
  List<RemoteWorkspaceProject> projects,
  List<CompanionSessionSummary> sessions,
) {
  final byKey = <String, List<CompanionSessionSummary>>{};
  for (final session in sessions) {
    (byKey[session.projectKey] ??= <CompanionSessionSummary>[]).add(session);
  }
  final seen = <String>{};
  final groups = <CompanionProjectGroup>[];
  for (final project in projects) {
    seen.add(project.projectId);
    groups.add(
      CompanionProjectGroup(
        key: project.projectId,
        project: project,
        sessions: List.unmodifiable(byKey[project.projectId] ?? const []),
      ),
    );
  }
  for (final group in groupByProject(sessions)) {
    if (!seen.contains(group.key)) groups.add(group);
  }
  return groups;
}
