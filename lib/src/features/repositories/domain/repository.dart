import 'package:agent_cli/process.dart';

/// A Git repository belonging to a [Project]. Its working-tree [path] is bound
/// to the execution environment that owns it.
class Repository {
  const Repository({
    required this.id,
    required this.projectId,
    required this.name,
    required this.path,
    required this.createdAt,
    this.canonicalId,
  });

  final String id;
  final String projectId;
  final String name;

  /// The repository's location, bound to its execution environment.
  final EnvironmentPath path;

  final DateTime createdAt;

  /// The repository this checkout *is*, derived from `origin` — and null
  /// whenever that could not be established.
  ///
  /// **Nullable by construction, not by accident.** A `git init` with no
  /// remote, a `file://` URL and a folder that is not a repository all leave it
  /// null, and so does a checkout the app has not read `origin` for yet. So
  /// nothing may key on it without falling back to today's path-only
  /// behaviour; see [canonicalRepositoryId] for the normalisation and
  /// `recordRepositoryIdentity` for when it is refreshed.
  final String? canonicalId;

  /// Convenience accessor for the environment the repository lives in.
  String get environmentId => path.environmentId;

  Repository copyWith({
    String? id,
    String? projectId,
    String? name,
    EnvironmentPath? path,
    DateTime? createdAt,
    String? canonicalId,
  }) => Repository(
    id: id ?? this.id,
    projectId: projectId ?? this.projectId,
    name: name ?? this.name,
    path: path ?? this.path,
    createdAt: createdAt ?? this.createdAt,
    canonicalId: canonicalId ?? this.canonicalId,
  );

  @override
  bool operator ==(Object other) =>
      other is Repository &&
      other.id == id &&
      other.projectId == projectId &&
      other.name == name &&
      other.path == path &&
      other.createdAt == createdAt &&
      other.canonicalId == canonicalId;

  @override
  int get hashCode =>
      Object.hash(id, projectId, name, path, createdAt, canonicalId);

  @override
  String toString() => 'Repository($id, $name, $path)';
}
