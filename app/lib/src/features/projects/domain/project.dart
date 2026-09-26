import 'package:agent_cli/process.dart';

/// A unit of work rooted at a folder. A project may contain many
/// repositories (modeled separately). Its [root] folder is bound to the
/// execution environment that owns it.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.root,
    required this.createdAt,
    this.workspaceId,
    this.defaultRepositoryId,
  });

  final String id;
  final String name;

  /// The project's root folder, bound to its execution environment.
  final EnvironmentPath root;

  final DateTime createdAt;

  /// The `Workspace` this project is filed under, or null for an unassigned
  /// project — which is an ordinary project, not one waiting to be fixed.
  final String? workspaceId;

  /// The checkout a one-click "New session" runs in. Null is not a gap: it
  /// means the project never chose, and the picker's own first row answers.
  final String? defaultRepositoryId;

  /// Convenience accessor for the environment the root folder lives in.
  String get environmentId => root.environmentId;

  Project copyWith({
    String? id,
    String? name,
    EnvironmentPath? root,
    DateTime? createdAt,
    String? workspaceId,
    String? defaultRepositoryId,
  }) => Project(
    id: id ?? this.id,
    name: name ?? this.name,
    root: root ?? this.root,
    createdAt: createdAt ?? this.createdAt,
    workspaceId: workspaceId ?? this.workspaceId,
    defaultRepositoryId: defaultRepositoryId ?? this.defaultRepositoryId,
  );

  /// [copyWith] cannot express "unassign", because null there means "leave it".
  Project withoutWorkspace() => Project(
    id: id,
    name: name,
    root: root,
    createdAt: createdAt,
    defaultRepositoryId: defaultRepositoryId,
  );

  /// [copyWith] cannot express "back to the picker's first row" either.
  Project withoutDefaultRepository() => Project(
    id: id,
    name: name,
    root: root,
    createdAt: createdAt,
    workspaceId: workspaceId,
  );

  @override
  bool operator ==(Object other) =>
      other is Project &&
      other.id == id &&
      other.name == name &&
      other.root == root &&
      other.createdAt == createdAt &&
      other.workspaceId == workspaceId &&
      other.defaultRepositoryId == defaultRepositoryId;

  @override
  int get hashCode =>
      Object.hash(id, name, root, createdAt, workspaceId, defaultRepositoryId);

  @override
  String toString() => 'Project($id, $name, $root)';
}
