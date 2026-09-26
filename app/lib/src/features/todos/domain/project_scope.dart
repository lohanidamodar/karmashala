import 'package:flutter/foundation.dart';

/// Which project's writing a surface is showing. **Three states**: `null`
/// would have to mean both "no filter" and "no project", which is the confusion.
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

  /// The project a new item written in this scope should be filed under. Looking
  /// at everything files it nowhere, which is the honest answer.
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
