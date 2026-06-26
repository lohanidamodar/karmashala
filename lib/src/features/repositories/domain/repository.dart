import '../../environments/domain/environment_path.dart';

/// A Git repository belonging to a [Project]. Its working-tree [path] is bound
/// to the execution environment that owns it.
class Repository {
  const Repository({
    required this.id,
    required this.projectId,
    required this.name,
    required this.path,
    required this.createdAt,
  });

  final String id;
  final String projectId;
  final String name;

  /// The repository's location, bound to its execution environment.
  final EnvironmentPath path;

  final DateTime createdAt;

  /// Convenience accessor for the environment the repository lives in.
  String get environmentId => path.environmentId;

  Repository copyWith({
    String? id,
    String? projectId,
    String? name,
    EnvironmentPath? path,
    DateTime? createdAt,
  }) => Repository(
    id: id ?? this.id,
    projectId: projectId ?? this.projectId,
    name: name ?? this.name,
    path: path ?? this.path,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Repository &&
      other.id == id &&
      other.projectId == projectId &&
      other.name == name &&
      other.path == path &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, projectId, name, path, createdAt);

  @override
  String toString() => 'Repository($id, $name, $path)';
}
