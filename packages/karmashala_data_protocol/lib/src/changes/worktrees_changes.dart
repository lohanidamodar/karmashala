part of '../data_change.dart';

// The git side tables: worktree setup and its runs, review threads.

DataChange? _worktreesChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'worktreeSetupChanged' => WorktreeSetupChanged(
        json['id']! as String,
        json['setup'] == null
            ? null
            : worktreeSetupFromJson(
                (json['setup']! as Map).cast<String, Object?>(),
              ),
      ),
      'worktreeRunRecorded' => WorktreeRunRecorded(
        setupReportFromJson(_row(json)),
      ),
      'reviewThreadChanged' => ReviewThreadChanged(
        reviewThreadFromJson(_row(json)),
      ),
      'worktreeRunRemoved' => WorktreeRunRemoved(json['id']! as String),
      'reviewThreadRemoved' => ReviewThreadRemoved(json['id']! as String),
      _ => null,
    };

/// A change to the git side tables.
sealed class WorktreesChange extends DataChange {
  const WorktreesChange();
}

/// Checkout [repositoryId]'s worktree setup as it now stands; null once it
/// asks for nothing.
final class WorktreeSetupChanged extends WorktreesChange {
  const WorktreeSetupChanged(this.repositoryId, this.setup);

  final String repositoryId;
  final WorktreeSetup? setup;

  @override
  Map<String, Object?> toJson() => {
    'change': 'worktreeSetupChanged',
    'id': repositoryId,
    'setup': setup == null ? null : worktreeSetupToJson(setup!),
  };
}

/// A worktree's setup verdict, recorded or corrected.
final class WorktreeRunRecorded extends WorktreesChange {
  const WorktreeRunRecorded(this.report);

  final WorktreeSetupReport report;

  @override
  Map<String, Object?> toJson() => {
    'change': 'worktreeRunRecorded',
    'row': setupReportToJson(report),
  };
}

/// A review thread with all its comments, as it now stands.
final class ReviewThreadChanged extends WorktreesChange {
  const ReviewThreadChanged(this.thread);

  final ReviewThread thread;

  @override
  Map<String, Object?> toJson() => {
    'change': 'reviewThreadChanged',
    'row': reviewThreadToJson(thread),
  };
}

/// The setup verdict kept under [key] went with its checkout.
final class WorktreeRunRemoved extends WorktreesChange {
  const WorktreeRunRemoved(this.key);

  final String key;

  @override
  Map<String, Object?> toJson() => {'change': 'worktreeRunRemoved', 'id': key};
}

/// Review thread [id] went with its checkout.
final class ReviewThreadRemoved extends WorktreesChange {
  const ReviewThreadRemoved(this.id);

  final String id;

  @override
  Map<String, Object?> toJson() => {'change': 'reviewThreadRemoved', 'id': id};
}
