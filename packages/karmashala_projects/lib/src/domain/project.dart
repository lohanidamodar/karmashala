import 'package:agent_cli/process.dart';

import 'row_json.dart';

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

  /// The wire shape: dates as ISO-8601 UTC, absent fields omitted.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'root': environmentPathToJson(root),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'workspaceId': ?workspaceId,
    'defaultRepositoryId': ?defaultRepositoryId,
  };

  /// Throws [FormatException] on a map that is not a project.
  static Project fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final createdAt = json['createdAt'];
    if (id is! String || name is! String || createdAt is! String) {
      throw const FormatException('not a project');
    }
    return Project(
      id: id,
      name: name,
      root: environmentPathFromJson(json['root']),
      createdAt: DateTime.parse(createdAt).toUtc(),
      workspaceId: json['workspaceId'] as String?,
      defaultRepositoryId: json['defaultRepositoryId'] as String?,
    );
  }

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
