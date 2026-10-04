import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:karmashala_session/session.dart';

/// One session as the cross-project lenses list it: a native row or an
/// imported conversation, with the project and folder it was filed under.
@immutable
class WorkspaceSessionEntry {
  const WorkspaceSessionEntry({
    required this.id,
    required this.title,
    required this.createdAt,
    this.projectName,
    this.directory,
    this.lastActiveAt,
    this.native,
    this.imported,
  });

  /// The workspace id the rest of the app keys this session by — the one the
  /// inbox and the status registry call `openId`.
  final String id;
  final String title;
  final DateTime createdAt;

  /// Null when the row's repository no longer belongs to a project.
  final String? projectName;

  /// Where the agent works: the session's worktree, else its repository.
  final EnvironmentPath? directory;

  /// The newest reading the app holds, or null when it holds none.
  final DateTime? lastActiveAt;

  final Session? native;
  final ImportedSession? imported;

  bool get isImported => native == null;

  /// The recorded lifecycle, null for an imported conversation, which has none.
  SessionStatus? get rowStatus => native?.status;

  /// What a list orders and dates this session by.
  DateTime get activityAt => lastActiveAt ?? createdAt;

  /// The last segment of [directory], or null when there is none.
  String? get folder {
    final path = directory?.path;
    if (path == null) return null;
    final segments = path
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    return segments.isEmpty ? null : segments.last;
  }

  @override
  bool operator ==(Object other) =>
      other is WorkspaceSessionEntry &&
      other.id == id &&
      other.title == title &&
      other.createdAt == createdAt &&
      other.projectName == projectName &&
      other.directory == directory &&
      other.lastActiveAt == lastActiveAt &&
      other.native == native &&
      other.imported?.id == imported?.id &&
      other.imported?.title == imported?.title &&
      other.imported?.updatedAt == imported?.updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    createdAt,
    projectName,
    directory,
    lastActiveAt,
    native,
    imported?.id,
  );

  @override
  String toString() => 'WorkspaceSessionEntry($id, $title)';
}

/// What a session's turn handed off to and is still running, for its row; null
/// when nothing is.
String? inFlightClause(List<String> work) => switch (work) {
  [] => null,
  [final only] => 'still running: $only',
  _ => '${work.length} still running',
};

/// The clauses that tell two same-titled sessions apart: the project, the
/// folder only when it is not just the project's name again, and the branch
/// only when a reading already named one. Never a guess at any of them.
List<String> sessionContextClauses({
  String? projectName,
  String? folder,
  String? branch,
}) {
  final project = projectName?.trim();
  final dir = folder?.trim();
  final head = branch?.trim();
  return [
    if (project != null && project.isNotEmpty) project,
    if (dir != null &&
        dir.isNotEmpty &&
        dir.toLowerCase() != (project ?? '').toLowerCase())
      dir,
    if (head != null && head.isNotEmpty) head,
  ];
}
