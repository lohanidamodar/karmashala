part of '../data_request.dart';

// The git side tables: worktree setup and its runs, review threads.

DataRequest<Object?>? _worktreesRequestFromJson(
  String kind,
  _Arguments args,
) => switch (kind) {
  WorktreesList.name => const WorktreesList(),
  WorktreeSetupSave.name => WorktreeSetupSave(
    args.string('repositoryId'),
    args.value('setup', worktreeSetupFromJson),
  ),
  WorktreeSetupClear.name => WorktreeSetupClear(args.string('repositoryId')),
  WorktreeSetupRecord.name => WorktreeSetupRecord(
    args.value('report', setupReportFromJson),
  ),
  ReviewThreadOpen.name => ReviewThreadOpen(
    id: args.string('id'),
    repositoryId: args.string('repositoryId'),
    anchor: args.value('anchor', reviewAnchorFromJson),
    author: args.string('author'),
    authorKind: ReviewAuthorKind.fromName(args.string('authorKind')),
    body: args.string('body'),
    status: args.optionalString('status') == null
        ? null
        : ReviewThreadStatus.fromName(args.optionalString('status')),
    sessionId: args.optionalString('sessionId'),
  ),
  ReviewThreadReply.name => ReviewThreadReply(
    threadId: args.string('threadId'),
    author: args.string('author'),
    authorKind: ReviewAuthorKind.fromName(args.string('authorKind')),
    body: args.string('body'),
  ),
  ReviewThreadSetStatus.name => ReviewThreadSetStatus(
    args.string('threadId'),
    ReviewThreadStatus.fromName(args.string('status')),
  ),
  _ => null,
};

/// A request of the git side tables.
sealed class WorktreesRequest<R> extends DataRequest<R> {
  const WorktreesRequest();
}

/// Every checkout's worktree setup, every recorded setup run and every review
/// thread with its comments.
final class WorktreesList extends WorktreesRequest<WorktreesSnapshot> {
  const WorktreesList();

  static const String name = 'worktrees.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(WorktreesSnapshot result) => result.toJson();

  @override
  WorktreesSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => WorktreesSnapshot.fromJson(_object(json, kind)));
}

/// Keeps [setup] for checkout [repositoryId]; one that asks for nothing clears
/// it. Refused [DataRefusalCode.notFound] for an unknown checkout.
final class WorktreeSetupSave extends _WorktreesAck {
  const WorktreeSetupSave(this.repositoryId, this.setup);

  static const String name = 'worktreeSetup.save';

  final String repositoryId;
  final WorktreeSetup setup;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'repositoryId': repositoryId,
    'setup': worktreeSetupToJson(setup),
  };
}

final class WorktreeSetupClear extends _WorktreesAck {
  const WorktreeSetupClear(this.repositoryId);

  static const String name = 'worktreeSetup.clear';

  final String repositoryId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'repositoryId': repositoryId};
}

/// Records how a worktree's setup went, replacing the earlier verdict for the
/// same worktree.
final class WorktreeSetupRecord extends _WorktreesAck {
  const WorktreeSetupRecord(this.report);

  static const String name = 'worktreeSetup.record';

  final WorktreeSetupReport report;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'report': setupReportToJson(report),
  };
}

/// Opens thread [id] on [anchor] with its first comment; the server stamps the
/// time, and an unset [status] is `defaultReviewStatus`. Refused for a blank
/// body, a taken id or an unknown checkout.
final class ReviewThreadOpen extends _ThreadAnswer {
  const ReviewThreadOpen({
    required this.id,
    required this.repositoryId,
    required this.anchor,
    required this.author,
    required this.authorKind,
    required this.body,
    this.status,
    this.sessionId,
  });

  static const String name = 'reviewThreads.open';

  final String id;
  final String repositoryId;
  final ReviewAnchor anchor;
  final String author;
  final ReviewAuthorKind authorKind;
  final String body;
  final ReviewThreadStatus? status;
  final String? sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'repositoryId': repositoryId,
    'anchor': reviewAnchorToJson(anchor),
    'author': author,
    'authorKind': authorKind.name,
    'body': body,
    'status': status?.name,
    'sessionId': sessionId,
  };
}

/// Appends a reply. Refused [DataRefusalCode.notFound] for a thread gone.
final class ReviewThreadReply extends _ThreadAnswer {
  const ReviewThreadReply({
    required this.threadId,
    required this.author,
    required this.authorKind,
    required this.body,
  });

  static const String name = 'reviewThreads.reply';

  final String threadId;
  final String author;
  final ReviewAuthorKind authorKind;
  final String body;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'threadId': threadId,
    'author': author,
    'authorKind': authorKind.name,
    'body': body,
  };
}

/// Moves a thread's status — the only change to what was written.
final class ReviewThreadSetStatus extends _ThreadAnswer {
  const ReviewThreadSetStatus(this.threadId, this.status);

  static const String name = 'reviewThreads.setStatus';

  final String threadId;
  final ReviewThreadStatus status;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'threadId': threadId,
    'status': status.name,
  };
}

sealed class _WorktreesAck extends WorktreesRequest<DataAck> {
  const _WorktreesAck();

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// A request answered with the thread as it now stands.
sealed class _ThreadAnswer extends WorktreesRequest<ReviewThread> {
  const _ThreadAnswer();

  @override
  Object? resultToJson(ReviewThread result) => reviewThreadToJson(result);

  @override
  ReviewThread resultFromJson(Object? json) =>
      _decode(kind, () => reviewThreadFromJson(_object(json, kind)));
}
