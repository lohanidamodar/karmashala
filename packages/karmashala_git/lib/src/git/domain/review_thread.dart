/// A **review comment as a durable, addressable thread**: an anchor, an
/// author, a body, a status, and replies — a row somebody can come back to,
/// rather than a marker on whatever the diff happened to look like at the
/// moment it was written.
///
/// ## What was here before, and why it was a bug
///
/// `DiffAnnotation` keyed a comment by `(repositoryId, path, diffIndex)`, where
/// `diffIndex` was **the row number of a line inside the currently rendered
/// unified diff**. That number is a property of a rendering, not of the code:
/// it moves when a hunk grows, when a neighbouring hunk appears, when git
/// merges two hunks that drift within three lines of each other, and when the
/// file is staged. So the moment the agent edited the file a comment was
/// attached to — which is the *whole point* of writing the comment — the
/// comment went on pointing at row 47 of a diff that no longer had the same
/// row 47. It did not report that. It just quietly meant something else.
///
/// A comment that points at the wrong lines is worse than one that is gone: the
/// missing one is visibly missing, and the wrong one is read and believed. The
/// annotations were also cleared on send, so in practice the bug was masked by
/// a second bug. Fixing the persistence without fixing the key would have
/// promoted the mis-anchoring from a transient to a stored one.
///
/// ## What an anchor is now
///
/// **Path plus blob sha plus an optional line range.** The blob sha is the git
/// hash of the file's bytes as they stood when the comment was written, so the
/// anchor names *the content the author was actually looking at* rather than a
/// position in a view of it. A range with no lines is a file-level comment,
/// which is a real thing a reviewer wants to say and not a degraded line
/// comment.
///
/// ## What happens when the file changes
///
/// The thread **detaches, and says so.** Nothing re-anchors it: no fuzzy
/// matching of the excerpt against the new content, no offset arithmetic, no
/// "the line moved down three". Those techniques are right most of the time,
/// and a re-anchor that is right most of the time is the same failure the
/// `diffIndex` key had — the reader cannot tell which case they are holding, so
/// they must distrust all of them, so the anchor is worth nothing. A detached
/// thread keeps its excerpt and the sha it was written against, and the reader
/// is told plainly that the file has moved on. That is less information than a
/// correct re-anchor and strictly more than a wrong one.
///
/// The one thing that *does* re-attach a thread is the file's content coming
/// back to the bytes it had — same content, same sha, same anchor. That is not
/// a guess: it is the identity the sha exists to state.
library;

/// Where a review thread stands with the person triaging it.
///
/// Four states, and the vocabulary matters because [shouldFix] is the one the
/// send path reads. "Pending" is not a synonym for "unresolved": a thread
/// nobody has looked at yet must not be handed to an agent as an instruction,
/// because nobody has decided it is one.
enum ReviewThreadStatus {
  /// Raised, and nobody has triaged it. The state a reviewer agent's finding
  /// starts in: it is a claim awaiting a human, not yet a request.
  open('Open'),

  /// Triaged, and the answer was yes. **This is the pending set** — the threads
  /// a send gathers.
  shouldFix('Should fix'),

  /// Read, and deliberately not acted on. Kept rather than deleted: "we looked
  /// at this and decided no" is an answer, and a thread that vanished would be
  /// raised again by the next reader.
  dismissed('Dismissed'),

  /// The change was made.
  resolved('Resolved'),

  /// A status this build does not know — a row from a newer schema, or a
  /// hand-edited database.
  ///
  /// Never written, only read, exactly like `DecisionKind.unrecognised` and
  /// `FileChangeType.unknown`. Its own state rather than folded into [open],
  /// because reading an unknown status as "nobody has triaged this" would put a
  /// resolved thread back in front of a human as new work.
  unrecognised('Status not recognised');

  const ReviewThreadStatus(this.label);

  /// Plain words for a reader.
  final String label;

  /// Whether a thread in this state is something the author still owes.
  ///
  /// Only [shouldFix]. Deliberately not [open]: see the enum's own doc.
  bool get isPending => this == ReviewThreadStatus.shouldFix;

  static ReviewThreadStatus fromName(String? name) => values.firstWhere(
    (status) => status.name == name,
    orElse: () => ReviewThreadStatus.unrecognised,
  );

  /// The statuses a caller may *set*, by name.
  ///
  /// [unrecognised] is absent because it is a read-time fallback and never a
  /// thing anybody chose.
  static const Set<String> settable = <String>{
    'open',
    'shouldFix',
    'dismissed',
    'resolved',
  };
}

/// Who wrote a comment.
///
/// Two real kinds and a fallback, and the distinction earns its column: it is
/// what decides the status a new thread starts in. A person writing on a diff
/// has already triaged what they wrote — they are the triager — so their thread
/// opens as [ReviewThreadStatus.shouldFix]. An agent's finding opens as
/// [ReviewThreadStatus.open], because an agent asserting that something should
/// be fixed is asserting exactly the thing a human review exists to decide.
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
/// Immutable and never rewritten. An anchor is a statement about a moment; the
/// way to comment on the new content is a new thread, not an edited anchor.
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
  /// A content fingerprint, and used as nothing else: it is never dereferenced
  /// as an object, never compared against the `index` line of a diff, never
  /// resolved through the object store. All that is ever asked of it is
  /// "are these the same bytes", which is the one question a sha answers
  /// without qualification — including across a checkout that put the old
  /// content back.
  final String blobSha;

  /// First line of the range, 1-based, **in the file as it stood at
  /// [blobSha]** — not a row of any diff. Null for a file-level thread.
  final int? startLine;

  /// Last line of the range, inclusive. Null when [startLine] is null; equal to
  /// [startLine] for a single-line anchor.
  final int? endLine;

  /// The text the author was looking at, stored verbatim.
  ///
  /// The evidence a detached thread is read by. It is deliberately **not** used
  /// to find the line again — see the library doc — but a human holding "you
  /// dropped the null check" next to the line it was written about can do in a
  /// second what no amount of fuzzy matching should be trusted to do at all.
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
  /// never [ReviewThreadAttachment.attached]. The same rule `ReviewBrief`
  /// applies to a missing file list: an unanswered question must not render as
  /// the reassuring answer.
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
  /// Not "attached", and not "detached" either: a thread whose file is missing
  /// is a thread nobody can check.
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

  /// Who wrote it, **in words a reader recognises** — "the user", an agent's
  /// display name. Words rather than an id, for the reason
  /// `DecisionRecord.decidedBy` gives: whoever reads this has no way to resolve
  /// a key.
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

  /// Which checkout's file the anchor is in. Threads are scoped to a
  /// repository rather than to a session because the *code* is what is being
  /// commented on, and it outlives every session that touches it.
  final String repositoryId;

  final ReviewAnchor anchor;

  final ReviewThreadStatus status;

  /// The session the thread was raised in or about, when there was one. Null
  /// for a comment somebody wrote with no session selected — which is a normal
  /// thing to do while reading a diff.
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
/// The pairing exists so that no renderer and no prompt builder can forget to
/// ask. A bare [ReviewThread] carries line numbers that look authoritative;
/// this type cannot be constructed without saying whether they still are.
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
/// Built once per read and shared by every widget that draws a line of the
/// diff, which is the point: the previous implementation had each line tile
/// scan the whole annotation list, and a DAO call per line would have been the
/// same shape with a database behind it. See `review_thread_cost_test`.
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
  /// A detached thread is deliberately **not** returned here: its line number
  /// is a number about a file that no longer exists in that form, and drawing
  /// it against the current line is the mis-anchoring this whole file is about.
  /// Detached threads are surfaced [forPath] instead, where the reader is told
  /// what happened to them.
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
  /// These are the ones a renderer would otherwise drop on the floor. A
  /// detached thread has a line number that no longer locates anything, so
  /// drawing it on that line would be a lie and drawing it nowhere would be a
  /// disappearance — it goes in a strip above the diff instead, where there is
  /// room to say what happened to it.
  List<AnchoredReviewThread> unplaced(String path) => [
    for (final entry in forPath(path))
      if (!entry.isAttached || entry.anchor.isFileLevel) entry,
  ];

  /// The threads a send hands to an agent: the ones somebody triaged as
  /// [ReviewThreadStatus.shouldFix], attached or not.
  ///
  /// Detached ones are included on purpose. "Fix the thing I asked about"
  /// remains a request after the file moves; what the prompt owes the agent is
  /// the truth that the line numbers are stale, and [buildReviewThreadPrompt]
  /// says exactly that rather than dropping the request.
  List<AnchoredReviewThread> get pending => [
    for (final entry in all)
      if (entry.thread.status.isPending) entry,
  ];
}

/// The message a send puts in front of an agent.
///
/// ## Why sending changes nothing
///
/// The old path cleared every annotation in the repository the moment it sent
/// one prompt, so a review comment existed for exactly as long as it took to
/// mention it once. Nothing survived to check the fix against, nothing could be
/// replied to, and a comment the agent ignored was indistinguishable from one
/// it addressed. Threads are not touched by sending: they stay
/// [ReviewThreadStatus.shouldFix] until somebody decides they are resolved,
/// which is a judgement about the code and not about whether a message went
/// out.
///
/// ## Why a detached thread is still sent
///
/// Because it is still a request. What changes is what the prompt claims: an
/// attached thread quotes a line and a number, a detached one says the file has
/// changed since the comment was written, quotes the text it was written
/// against, and asks the agent to find it. That is the honest version of the
/// same instruction, and it is strictly better than the alternatives — dropping
/// the request, or repeating a line number that now points somewhere else.
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
