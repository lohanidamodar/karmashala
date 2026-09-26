import 'package:karmashala_projects/karmashala_projects.dart';

/// What the project list is narrowed to. Three states: everything, one
/// context, or the projects filed under none — which must stay reachable.
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

  /// How the scope is kept in settings: empty for [all], `none` for
  /// [unassigned], `ctx:<id>` for a context. Prefixed, so no generated id
  /// can spell `none`.
  String get stored => isAll
      ? ''
      : unassignedOnly
      ? _storedUnassigned
      : '$_storedContext$workspaceId';

  /// [stored], read back. Anything unrecognised is [all].
  static WorkspaceScope parse(String stored) {
    if (stored == _storedUnassigned) return unassigned;
    if (stored.startsWith(_storedContext) &&
        stored.length > _storedContext.length) {
      return WorkspaceScope.of(stored.substring(_storedContext.length));
    }
    return all;
  }

  static const _storedUnassigned = 'none';
  static const _storedContext = 'ctx:';

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
