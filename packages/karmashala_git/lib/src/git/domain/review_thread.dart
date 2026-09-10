/// A **review comment as a durable, addressable thread**: an anchor, an author,
/// a body, a status, and replies.
///
/// An anchor is path plus blob sha plus an optional line range, never a row of a
/// rendered diff. When the file changes the thread detaches and says so; nothing
/// re-anchors it, because a re-anchor that is right most of the time cannot be
/// told from a wrong one, so none of them can be trusted.
library;

/// Where a review thread stands with the person triaging it.
///
/// "Pending" is not a synonym for "unresolved": a thread nobody has triaged must
/// not be handed to an agent as an instruction. [shouldFix] is the one that is.
enum ReviewThreadStatus {
  /// Raised, and nobody has triaged it. The state a reviewer agent's finding
  /// starts in: it is a claim awaiting a human, not yet a request.
  open('Open'),

  /// Triaged, and the answer was yes. **This is the pending set** — the threads
  /// a send gathers.
  shouldFix('Should fix'),

  /// Read, and deliberately not acted on. Kept rather than deleted, so the next
  /// reader does not raise it again.
  dismissed('Dismissed'),

  /// The change was made.
  resolved('Resolved'),

  /// A status this build does not know — a newer schema, or a hand-edited row.
  /// Never written, only read; not folded into [open], which would put a
  /// resolved thread back in front of a human as new work.
  unrecognised('Status not recognised');

  const ReviewThreadStatus(this.label);

  /// Plain words for a reader.
  final String label;

  /// Whether the author still owes this. Only [shouldFix], deliberately not [open].
  bool get isPending => this == ReviewThreadStatus.shouldFix;

  static ReviewThreadStatus fromName(String? name) => values.firstWhere(
    (status) => status.name == name,
    orElse: () => ReviewThreadStatus.unrecognised,
  );

  /// The statuses a caller may *set*. [unrecognised] is a read-time fallback only.
  static const Set<String> settable = <String>{
    'open',
    'shouldFix',
    'dismissed',
    'resolved',
  };
}

/// Who wrote a comment.
///
/// The kind decides the status a new thread starts in: a person has already
/// triaged what they wrote, an agent's finding has not.
enum ReviewAuthorKind {
  user('the user'),
  agent('an agent'),
  unrecognised('an author this build does not recognise');

  const ReviewAuthorKind(this.label);

  final String label;

  static ReviewAuthorKind fromName(String? name) => values.firstWhere(
    (kind) => kind.name == name,
    orElse: () => ReviewAuthorKind.unrecognised,
  );
}

/// The content a thread is attached to, and where in it.
///
/// Immutable and never rewritten — the way to comment on the new content is a
/// new thread, not an edited anchor.
class ReviewAnchor {
  const ReviewAnchor({
    required this.path,
    required this.blobSha,
    this.startLine,
    this.endLine,
    this.excerpt,
  });

  /// Repository-relative, as git spells it.
  final String path;

  /// `git hash-object` of the file's bytes when the thread was opened.
  ///
  /// A content fingerprint and nothing else: never dereferenced as an object,
  /// never compared against a diff's `index` line. Only "are these the same bytes".
  final String blobSha;

  /// First line of the range, 1-based, **in the file as it stood at
  /// [blobSha]** — not a row of any diff. Null for a file-level thread.
  final int? startLine;

  /// Last line of the range, inclusive. Null when [startLine] is null; equal to
  /// [startLine] for a single-line anchor.
  final int? endLine;

  /// The text the author was looking at, stored verbatim.
  ///
  /// The evidence a detached thread is read by, and deliberately **not** used to
  /// find the line again.
  final String? excerpt;

  /// Whether this thread is about the file rather than a place in it.
  bool get isFileLevel => startLine == null;

  /// The range in the words a reader uses: `lib/a.dart:12`, `lib/a.dart:12-18`,
  /// or just the path.
  String get location {
    final start = startLine;
    if (start == null) return path;
    final end = endLine;
    if (end == null || end == start) return '$path:$start';
    return '$path:$start-$end';
  }

  /// Whether [currentBlobSha] is the content this anchor was written against.
  ///
  /// Null — "git could not be asked" — is [ReviewThreadAttachment.unknown] and
  /// never [ReviewThreadAttachment.attached].
  ReviewThreadAttachment attachmentAgainst(String? currentBlobSha) {
    if (currentBlobSha == null) return ReviewThreadAttachment.unknown;
    return currentBlobSha == blobSha
        ? ReviewThreadAttachment.attached
        : ReviewThreadAttachment.detached;
  }
}

/// Whether a thread still points at the code it was written about.
enum ReviewThreadAttachment {
  /// The file's bytes are the bytes the comment was written against, so the
  /// line range means what it meant.
  attached,

  /// The file has changed. The comment still says what it said; **the line
  /// numbers no longer locate anything**, and nothing here pretends otherwise.
  detached,

  /// The file could not be read — deleted, unreadable, or git would not answer.
  /// Neither attached nor detached: nobody can check it.
  unknown;

  bool get isAttached => this == ReviewThreadAttachment.attached;
}

/// One message in a thread. The opening comment and every reply are the same
/// shape, because a reply that could not be told from an opening comment is
/// exactly what a thread is.
class ReviewComment {
  const ReviewComment({
    required this.threadId,
    required this.sequence,
    required this.author,
    required this.authorKind,
    required this.body,
    required this.createdAt,
    this.id,
  });

  /// Database rowid; null before it is written.
  final int? id;

  final String threadId;

  /// 1-based position within the thread, assigned on append.
  final int sequence;

  /// Who wrote it, **in words a reader recognises** rather than an id: whoever
  /// reads this has no way to resolve a key.
  final String author;

  final ReviewAuthorKind authorKind;

  /// The comment, stored exactly as written and never summarised.
  final String body;

  final DateTime createdAt;

  ReviewComment copyWith({int? id, int? sequence}) => ReviewComment(
    id: id ?? this.id,
    threadId: threadId,
    sequence: sequence ?? this.sequence,
    author: author,
    authorKind: authorKind,
    body: body,
    createdAt: createdAt,
  );
}

/// A review comment and everything said under it.
class ReviewThread {
  const ReviewThread({
    required this.id,
    required this.repositoryId,
    required this.anchor,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.sessionId,
    this.comments = const [],
  });

  final String id;

  /// Which checkout's file the anchor is in. Scoped to the repository, not the
  /// session, because the code outlives every session that touches it.
  final String repositoryId;

  final ReviewAnchor anchor;

  final ReviewThreadStatus status;

  /// The session the thread was raised in or about. Null is normal — somebody
  /// reading a diff with no session selected.
  final String? sessionId;

  final DateTime createdAt;

  /// When the thread last changed — a reply, or a status move. What a list
  /// orders by, so the thread somebody just triaged is where they left it.
  final DateTime updatedAt;

  /// Oldest first: the opening comment, then the replies in the order they
  /// were made.
  final List<ReviewComment> comments;

  /// What the thread is about, for a one-line rendering. Empty when the thread
  /// somehow has no comments, which the DAO does not produce.
  String get body => comments.isEmpty ? '' : comments.first.body;

  /// Everything after the opening comment.
  List<ReviewComment> get replies =>
      comments.isEmpty ? const [] : comments.sublist(1);

  ReviewThread copyWith({
    ReviewThreadStatus? status,
    DateTime? updatedAt,
    List<ReviewComment>? comments,
  }) => ReviewThread(
    id: id,
    repositoryId: repositoryId,
    anchor: anchor,
    status: status ?? this.status,
    sessionId: sessionId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    comments: comments ?? this.comments,
  );

  @override
  String toString() => 'ReviewThread($id, ${anchor.location}, ${status.name})';
}

/// A thread with its anchor already held against the file on disk.
///
/// A bare [ReviewThread] carries line numbers that look authoritative; this type
/// cannot be constructed without saying whether they still are.
class AnchoredReviewThread {
  const AnchoredReviewThread(this.thread, this.attachment);

  final ReviewThread thread;
  final ReviewThreadAttachment attachment;

  ReviewAnchor get anchor => thread.anchor;

  /// Whether the line range can be drawn against the current file.
  bool get isAttached => attachment.isAttached;
}

/// Every open thread in one repository, with each anchor already checked.
///
/// Built once per read and shared by every widget that draws a diff line; the
/// alternative is a scan, or a DAO call, per line (`review_thread_cost_test`).
class ReviewThreadIndex {
  ReviewThreadIndex(List<AnchoredReviewThread> threads)
    : all = List.unmodifiable(threads),
      _byPath = _group(threads);

  const ReviewThreadIndex._empty()
    : all = const [],
      _byPath = const <String, List<AnchoredReviewThread>>{};

  /// An index over nothing — no repository selected, or none read yet.
  static const ReviewThreadIndex empty = ReviewThreadIndex._empty();

  final List<AnchoredReviewThread> all;
  final Map<String, List<AnchoredReviewThread>> _byPath;

  static Map<String, List<AnchoredReviewThread>> _group(
    List<AnchoredReviewThread> threads,
  ) {
    final byPath = <String, List<AnchoredReviewThread>>{};
    for (final thread in threads) {
      (byPath[thread.anchor.path] ??= <AnchoredReviewThread>[]).add(thread);
    }
    return byPath;
  }

  bool get isEmpty => all.isEmpty;

  /// Threads on one file, in the order the DAO returned them.
  List<AnchoredReviewThread> forPath(String path) =>
      _byPath[path] ?? const <AnchoredReviewThread>[];

  /// Threads whose anchor lands on [line] of [path], and which still attach.
  ///
  /// A detached thread is deliberately **not** returned: its line number is
  /// about a file that no longer exists in that form. [unplaced] surfaces it.
  List<AnchoredReviewThread> atLine(String path, int line) => [
    for (final entry in forPath(path))
      if (entry.isAttached &&
          entry.anchor.startLine != null &&
          line >= entry.anchor.startLine! &&
          line <= (entry.anchor.endLine ?? entry.anchor.startLine!))
        entry,
  ];

  /// Threads on [path] that **no line of the diff can carry**: file-level
  /// anchors, and every thread whose file has moved on.
  ///
  /// A renderer would otherwise drop them: on their old line would be a lie,
  /// nowhere would be a disappearance. They go in a strip above the diff.
  List<AnchoredReviewThread> unplaced(String path) => [
    for (final entry in forPath(path))
      if (!entry.isAttached || entry.anchor.isFileLevel) entry,
  ];

  /// The threads a send hands to an agent: the ones somebody triaged as
  /// [ReviewThreadStatus.shouldFix], attached or not.
  ///
  /// Detached ones are included on purpose; [buildReviewThreadPrompt] tells the
  /// agent the line numbers are stale rather than dropping the request.
  List<AnchoredReviewThread> get pending => [
    for (final entry in all)
      if (entry.thread.status.isPending) entry,
  ];
}

/// The message a send puts in front of an agent.
///
/// Sending changes nothing: threads stay [ReviewThreadStatus.shouldFix] until
/// somebody decides the code is right. A detached thread is still sent, with the
/// prompt saying the file has changed rather than repeating a stale line number.
String buildReviewThreadPrompt(List<AnchoredReviewThread> threads) {
  final buffer = StringBuffer(
    'Please address these review comments. Keep each requested change scoped '
    'to the referenced file and verify the result:\n',
  );
  for (final entry in threads) {
    final anchor = entry.anchor;
    buffer.write('\n- `${anchor.location}`');
    switch (entry.attachment) {
      case ReviewThreadAttachment.attached:
        buffer.write('\n');
      case ReviewThreadAttachment.detached:
        buffer.write(
          '\n  NOTE: the file has changed since this comment was written, so '
          'the line number above is where it *was*. Find the code the excerpt '
          'quotes; do not trust the position.\n',
        );
      case ReviewThreadAttachment.unknown:
        buffer.write(
          '\n  NOTE: this file could not be read just now, so whether the '
          'comment still points at the right lines is unknown. Check before '
          'you act on the position.\n',
        );
    }
    if (anchor.excerpt case final excerpt? when excerpt.trim().isNotEmpty) {
      buffer.write('  Code: `${excerpt.trim().replaceAll('`', r'\`')}`\n');
    }
    for (final comment in entry.thread.comments) {
      buffer.write(
        '  ${comment.sequence == 1 ? 'Review' : 'Reply'} '
        '(${comment.author}): ${comment.body.trim()}\n',
      );
    }
  }
  return buffer.toString().trimRight();
}
