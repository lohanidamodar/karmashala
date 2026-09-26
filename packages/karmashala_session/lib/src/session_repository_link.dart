/// Roles a repository can play within a session.
class SessionRepositoryRole {
  const SessionRepositoryRole._();
  static const primary = 'primary';
  static const additional = 'additional';
}

/// One repository link of a session (the `session_repositories` table).
class SessionRepositoryLink {
  const SessionRepositoryLink({required this.repositoryId, required this.role});

  final String repositoryId;
  final String role;

  bool get isPrimary => role == SessionRepositoryRole.primary;

  Map<String, Object?> toJson() => {
    'repositoryId': repositoryId,
    'role': role,
  };

  static SessionRepositoryLink fromJson(Map<String, Object?> json) {
    final repositoryId = json['repositoryId'];
    final role = json['role'];
    if (repositoryId is! String || role is! String) {
      throw const FormatException('not a session repository link');
    }
    return SessionRepositoryLink(repositoryId: repositoryId, role: role);
  }

  @override
  bool operator ==(Object other) =>
      other is SessionRepositoryLink &&
      other.repositoryId == repositoryId &&
      other.role == role;

  @override
  int get hashCode => Object.hash(repositoryId, role);

  @override
  String toString() => 'SessionRepositoryLink($repositoryId, $role)';
}

/// A session's links in the table's order: the primary first, then by
/// repository id.
List<SessionRepositoryLink> orderedLinks(Iterable<SessionRepositoryLink> all) =>
    [...all]..sort((a, b) {
      if (a.isPrimary != b.isPrimary) return a.isPrimary ? -1 : 1;
      return a.repositoryId.compareTo(b.repositoryId);
    });
