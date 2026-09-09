import '../../../core/database/app_database.dart';
import '../../../core/database/row_mapping.dart';
import 'package:karmashala_git/git.dart';

/// Data access for review threads and their comments (schema v30).
///
/// ## What is and is not mutable here
///
/// The **anchor is immutable** and there is no method to change it. That is the
/// whole discipline of this feature expressed as a missing API: an anchor is a
/// statement about the content somebody was looking at, and a method that
/// rewrote it would be the fuzzy re-anchoring `review_thread.dart` argues
/// against, wearing a DAO's name. When the content moves the thread detaches;
/// the way to comment on the new content is a new thread.
///
/// Comments are **append-only** for the reason `DecisionRecordDao` gives about
/// decisions: a review conversation that can be edited afterwards is not
/// evidence of what was asked. What *is* mutable is [setStatus], and only that
/// — triage is a judgement people revise, and a thread that could never move
/// from `open` to `dismissed` and back would push every reader to delete rather
/// than to decide.
///
/// ## Why the reads are counted
///
/// [forRepository] is what the diff view calls on every render, and it is
/// deliberately **two statements regardless of how many threads there are** —
/// one for the threads, one for every comment belonging to them, joined in
/// Dart. The obvious shape (read the threads, then a comment query per thread)
/// is a query per review comment on every frame of a panel that redraws on a
/// git poll. See `review_thread_cost_test`.
class ReviewThreadDao {
  ReviewThreadDao(this._db);

  final AppDatabase _db;

  /// Opens a thread with its first comment, in one transaction.
  ///
  /// One transaction because a thread with no comments is not a review comment
  /// — it is an anchor pointing at nothing, and it would render as a marker on
  /// a line with no text behind it. There is no way to create the empty shell.
  ReviewThread open({
    required String id,
    required String repositoryId,
    required ReviewAnchor anchor,
    required ReviewThreadStatus status,
    required String author,
    required ReviewAuthorKind authorKind,
    required String body,
    required DateTime now,
    String? sessionId,
  }) {
    return _db.transaction(() {
      _db.execute(
        'INSERT INTO review_threads (id, repository_id, file_path, blob_sha, '
        'start_line, end_line, anchor_excerpt, status, session_id, '
        'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        [
          id,
          repositoryId,
          anchor.path,
          anchor.blobSha,
          anchor.startLine,
          anchor.endLine,
          anchor.excerpt,
          status.name,
          sessionId,
          isoFromDate(now),
          isoFromDate(now),
        ],
      );
      final comment = _appendComment(
        threadId: id,
        author: author,
        authorKind: authorKind,
        body: body,
        now: now,
      );
      return ReviewThread(
        id: id,
        repositoryId: repositoryId,
        anchor: anchor,
        status: status,
        sessionId: sessionId,
        createdAt: now,
        updatedAt: now,
        comments: [comment],
      );
    });
  }

  /// Appends a reply and returns the thread as it now stands, or null when the
  /// thread is gone.
  ///
  /// The reply and the `updated_at` bump are one transaction: a thread whose
  /// newest comment is newer than its own timestamp would sort behind threads
  /// nothing has happened to, which is the one thing the ordering exists to
  /// prevent.
  ReviewThread? reply({
    required String threadId,
    required String author,
    required ReviewAuthorKind authorKind,
    required String body,
    required DateTime now,
  }) {
    return _db.transaction(() {
      if (getById(threadId) == null) return null;
      _appendComment(
        threadId: threadId,
        author: author,
        authorKind: authorKind,
        body: body,
        now: now,
      );
      _db.execute('UPDATE review_threads SET updated_at = ? WHERE id = ?;', [
        isoFromDate(now),
        threadId,
      ]);
      return getById(threadId);
    });
  }

  /// Moves a thread's status. Returns the thread, or null when it is gone.
  ///
  /// The only mutation in this file, and it changes nothing anybody wrote — the
  /// comments and the anchor are exactly as they were. Triage is revisable
  /// precisely because it is a judgement rather than a record.
  ReviewThread? setStatus(
    String threadId,
    ReviewThreadStatus status, {
    required DateTime now,
  }) {
    return _db.transaction(() {
      if (getById(threadId) == null) return null;
      _db.execute(
        'UPDATE review_threads SET status = ?, updated_at = ? WHERE id = ?;',
        [status.name, isoFromDate(now), threadId],
      );
      return getById(threadId);
    });
  }

  ReviewThread? getById(String id) {
    final rows = _db.query('SELECT * FROM review_threads WHERE id = ?;', [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first, _commentsForThreads([id])[id] ?? const []);
  }

  /// Every thread on [repositoryId], newest activity first.
  ///
  /// Two statements, always. See the class doc.
  List<ReviewThread> forRepository(
    String repositoryId, {
    String? path,
    Set<ReviewThreadStatus>? statuses,
  }) {
    final rows = _db.query(
      'SELECT * FROM review_threads WHERE repository_id = ? '
      '${path == null ? '' : 'AND file_path = ? '}'
      'ORDER BY updated_at DESC, id;',
      [repositoryId, ?path],
    );
    final kept = [
      for (final row in rows)
        if (statuses == null ||
            statuses.contains(ReviewThreadStatus.fromName(
              row['status'] as String?,
            )))
          row,
    ];
    final comments = _commentsForThreads([
      for (final row in kept) row['id']! as String,
    ]);
    return [
      for (final row in kept)
        _fromRow(row, comments[row['id']! as String] ?? const []),
    ];
  }

  ReviewComment _appendComment({
    required String threadId,
    required String author,
    required ReviewAuthorKind authorKind,
    required String body,
    required DateTime now,
  }) {
    final rows = _db.query(
      'SELECT COALESCE(MAX(sequence), 0) AS max_seq FROM '
      'review_thread_comments WHERE thread_id = ?;',
      [threadId],
    );
    final sequence = (rows.first['max_seq']! as int) + 1;
    _db.execute(
      'INSERT INTO review_thread_comments (thread_id, sequence, author, '
      'author_kind, body, created_at) VALUES (?, ?, ?, ?, ?, ?);',
      [threadId, sequence, author, authorKind.name, body, isoFromDate(now)],
    );
    return ReviewComment(
      id: _db.lastInsertRowId,
      threadId: threadId,
      sequence: sequence,
      author: author,
      authorKind: authorKind,
      body: body,
      createdAt: now,
    );
  }

  /// Every comment on [threadIds], in **one** statement, grouped by thread.
  Map<String, List<ReviewComment>> _commentsForThreads(List<String> threadIds) {
    if (threadIds.isEmpty) return const {};
    final placeholders = List.filled(threadIds.length, '?').join(', ');
    final rows = _db.query(
      'SELECT * FROM review_thread_comments WHERE thread_id IN '
      '($placeholders) ORDER BY thread_id, sequence;',
      threadIds,
    );
    final byThread = <String, List<ReviewComment>>{};
    for (final row in rows) {
      final threadId = row['thread_id']! as String;
      (byThread[threadId] ??= <ReviewComment>[]).add(
        ReviewComment(
          id: row['id']! as int,
          threadId: threadId,
          sequence: row['sequence']! as int,
          author: row['author']! as String,
          authorKind: ReviewAuthorKind.fromName(row['author_kind'] as String?),
          body: row['body']! as String,
          createdAt: dateFromIso(row['created_at']),
        ),
      );
    }
    return byThread;
  }

  ReviewThread _fromRow(
    Map<String, Object?> row,
    List<ReviewComment> comments,
  ) => ReviewThread(
    id: row['id']! as String,
    repositoryId: row['repository_id']! as String,
    anchor: ReviewAnchor(
      path: row['file_path']! as String,
      blobSha: row['blob_sha']! as String,
      startLine: row['start_line'] as int?,
      endLine: row['end_line'] as int?,
      excerpt: row['anchor_excerpt'] as String?,
    ),
    status: ReviewThreadStatus.fromName(row['status'] as String?),
    sessionId: row['session_id'] as String?,
    createdAt: dateFromIso(row['created_at']),
    updatedAt: dateFromIso(row['updated_at']),
    comments: comments,
  );
}
