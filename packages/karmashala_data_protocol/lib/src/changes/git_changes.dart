part of '../data_change.dart';

// What the server's git work moved (slice 3b). None is a row a client
// copies: each says what to read again, or carries a record in flight.

DataChange? _gitChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'checkoutTouched' => CheckoutTouched(
        environmentId: json['environmentId']! as String,
        path: json['path']! as String,
        repositoryId: json['repositoryId'] as String?,
        cause: CheckoutTouchCause.fromName(json['cause']),
      ),
      'worktreeCreationChanged' => WorktreeCreationChanged(
        json['id']! as String,
        environmentPathFromJson(json['repo']),
        WorktreeCreationRecord.fromJson(json['record']) ??
            (throw const FormatException('not a creation record')),
      ),
      'worktreeCleanupChanged' => WorktreeCleanupChanged(
        WorktreeCleanupLog.fromJson(_row(json)),
      ),
      _ => null,
    };

/// A change git work at the server made.
sealed class GitChange extends DataChange {
  const GitChange();
}

/// The checkout at [path] in [environmentId] may read differently now —
/// the server wrote to it, an agent working there ended a turn, or a
/// worktree of it came or went. A client that shows it asks again; nothing
/// polls. [repositoryId] is the recorded checkout, when one names it.
final class CheckoutTouched extends GitChange {
  const CheckoutTouched({
    required this.environmentId,
    required this.path,
    required this.cause,
    this.repositoryId,
  });

  final String environmentId;
  final String path;
  final String? repositoryId;
  final CheckoutTouchCause cause;

  EnvironmentPath get directory =>
      EnvironmentPath(environmentId: environmentId, path: path);

  @override
  Map<String, Object?> toJson() => {
    'change': 'checkoutTouched',
    'environmentId': environmentId,
    'path': path,
    'repositoryId': ?repositoryId,
    'cause': cause.name,
  };
}

/// Worktree creation [creationId] of [repo] has moved a stage: its record
/// as it now stands. Finished records are told once more and then no more.
final class WorktreeCreationChanged extends GitChange {
  const WorktreeCreationChanged(this.creationId, this.repo, this.record);

  final String creationId;
  final EnvironmentPath repo;
  final WorktreeCreationRecord record;

  @override
  Map<String, Object?> toJson() => {
    'change': 'worktreeCreationChanged',
    'id': creationId,
    'repo': environmentPathToJson(repo),
    'record': record.toJson(),
  };
}

/// Worktree cleanup swept: its log and last sweep as they now stand.
final class WorktreeCleanupChanged extends GitChange {
  const WorktreeCleanupChanged(this.log);

  final WorktreeCleanupLog log;

  @override
  Map<String, Object?> toJson() => {
    'change': 'worktreeCleanupChanged',
    'row': log.toJson(),
  };
}
