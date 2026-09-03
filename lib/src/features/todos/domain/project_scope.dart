import 'package:flutter/foundation.dart';

/// Which project's writing a surface is showing: everything, one project, or
/// the things filed under nothing.
///
/// **Three states, not two.** "Filed under nothing" is a place you can go and
/// look, not the leftover of a filter — an unfiled todo has to be as findable
/// as a filed one, or filing quietly becomes compulsory. That is the whole
/// reason this is a small type instead of a nullable project id: `null` would
/// have to mean both "no filter" and "no project", and those are the two
/// answers a person most needs to tell apart.
///
/// Shared by the Todos and Notes panels, which ask the same question of two
/// tables. It lives beside `Todo` rather than in a shell-wide widget folder
/// because it is a fact about these two features, not about the shell.
@immutable
class ProjectScope {
  const ProjectScope._(this.projectId, this.unfiledOnly);

  /// Everything, filed or not. The default, so neither state is privileged.
  static const all = ProjectScope._(null, false);

  /// Only what is filed under no project.
  static const unfiled = ProjectScope._(null, true);

  /// Only what is filed under [id].
  const ProjectScope.project(String id) : projectId = id, unfiledOnly = false;

  final String? projectId;
  final bool unfiledOnly;

  bool get isAll => projectId == null && !unfiledOnly;

  /// Whether something filed under [id] (or under nothing, when null) belongs
  /// in this scope.
  bool contains(String? id) {
    if (isAll) return true;
    return unfiledOnly ? id == null : id == projectId;
  }

  /// The project a new item written in this scope should be filed under.
  ///
  /// Looking at one project and typing a todo files it there; looking at
  /// everything files it nowhere, which is the honest answer — "all" is not a
  /// project, and guessing one would file work under whatever happened to be
  /// first in a menu.
  String? get projectForNewItems => projectId;

  @override
  bool operator ==(Object other) =>
      other is ProjectScope &&
      other.projectId == projectId &&
      other.unfiledOnly == unfiledOnly;

  @override
  int get hashCode => Object.hash(projectId, unfiledOnly);

  @override
  String toString() =>
      isAll ? 'ProjectScope.all' : 'ProjectScope(${projectId ?? 'unfiled'})';
}
