import '../../projects/domain/project.dart';

/// What the project list is narrowed to.
///
/// Three states, not two: [all] is the default and shows everything;
/// [WorkspaceScope.of] shows one context; [unassigned] shows the projects that
/// belong to no context. The third exists because a project with no workspace
/// must stay reachable *as such* — otherwise the only way to find the ones you
/// never filed would be to read all 31 rows looking for a missing badge.
class WorkspaceScope {
  const WorkspaceScope._(this.workspaceId, this.unassignedOnly);

  /// Every project, filed or not. The default, and the cheap common case.
  static const all = WorkspaceScope._(null, false);

  /// Only the projects belonging to no workspace.
  static const unassigned = WorkspaceScope._(null, true);

  /// Only the projects filed under [id].
  const WorkspaceScope.of(String id) : this._(id, false);

  /// The workspace being shown, or null for [all] and [unassigned].
  final String? workspaceId;

  final bool unassignedOnly;

  bool get isAll => workspaceId == null && !unassignedOnly;

  bool includes(Project project) =>
      isAll ||
      (unassignedOnly
          ? project.workspaceId == null
          : project.workspaceId == workspaceId);

  @override
  bool operator ==(Object other) =>
      other is WorkspaceScope &&
      other.workspaceId == workspaceId &&
      other.unassignedOnly == unassignedOnly;

  @override
  int get hashCode => Object.hash(workspaceId, unassignedOnly);

  @override
  String toString() => isAll
      ? 'WorkspaceScope.all'
      : unassignedOnly
      ? 'WorkspaceScope.unassigned'
      : 'WorkspaceScope.of($workspaceId)';
}
