import '../../environments/domain/environment_path.dart';
import 'session_status.dart';

/// A unit of work targeting one repository, run by one agent installation.
///
/// Every session records an explicit, per-session choice of whether it runs in a
/// dedicated Git **worktree** ([useWorktree]) or directly in the repository.
/// When a worktree is used, [worktree] is its location (bound to an
/// environment). Worktree lifecycle itself arrives in Loop 5; in Loop 1 the
/// fields are merely persisted.
class Session {
  const Session({
    required this.id,
    required this.repositoryId,
    required this.agentInstallationId,
    required this.title,
    required this.useWorktree,
    required this.status,
    required this.createdAt,
    this.worktree,
  });

  final String id;
  final String repositoryId;
  final String agentInstallationId;
  final String title;

  /// Whether this session runs in a dedicated Git worktree.
  final bool useWorktree;

  /// The worktree location when [useWorktree] is true and it has been created;
  /// otherwise `null`.
  final EnvironmentPath? worktree;

  final SessionStatus status;
  final DateTime createdAt;

  Session copyWith({
    String? id,
    String? repositoryId,
    String? agentInstallationId,
    String? title,
    bool? useWorktree,
    EnvironmentPath? worktree,
    SessionStatus? status,
    DateTime? createdAt,
  }) => Session(
    id: id ?? this.id,
    repositoryId: repositoryId ?? this.repositoryId,
    agentInstallationId: agentInstallationId ?? this.agentInstallationId,
    title: title ?? this.title,
    useWorktree: useWorktree ?? this.useWorktree,
    worktree: worktree ?? this.worktree,
    status: status ?? this.status,
    createdAt: createdAt ?? this.createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Session &&
      other.id == id &&
      other.repositoryId == repositoryId &&
      other.agentInstallationId == agentInstallationId &&
      other.title == title &&
      other.useWorktree == useWorktree &&
      other.worktree == worktree &&
      other.status == status &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    repositoryId,
    agentInstallationId,
    title,
    useWorktree,
    worktree,
    status,
    createdAt,
  );

  @override
  String toString() => 'Session($id, $title, $status)';
}
