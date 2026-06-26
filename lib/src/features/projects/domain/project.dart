import '../../environments/domain/environment_path.dart';

/// A logical workspace rooted at a folder. A project may contain many
/// repositories (modeled separately). Its [root] folder is bound to the
/// execution environment that owns it.
class Project {
  const Project({
    required this.id,
    required this.name,
    required this.root,
    required this.createdAt,
  });

  final String id;
  final String name;

  /// The project's root folder, bound to its execution environment.
  final EnvironmentPath root;

  final DateTime createdAt;

  /// Convenience accessor for the environment the root folder lives in.
  String get environmentId => root.environmentId;

  Project copyWith({
    String? id,
    String? name,
    EnvironmentPath? root,
    DateTime? createdAt,
  }) => Project(
    id: id ?? this.id,
    name: name ?? this.name,
    root: root ?? this.root,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Project &&
      other.id == id &&
      other.name == name &&
      other.root == root &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, root, createdAt);

  @override
  String toString() => 'Project($id, $name, $root)';
}
