import 'package:karmashala_store/database.dart';
import 'package:karmashala_git/git.dart';

/// Review threads and their comments. The server's alone. Anchors are
/// immutable and comments append-only — only [setStatus] mutates.
class ReviewThreadDao {
  ReviewThreadDao(this._db);

  final AppDatabase _db;

  /// Opens a thread with its first comment, in one transaction — a thread with
  /// no comments would render as a marker with no text behind it, and there is
  /// no way to create that empty shell.
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

  /// Appends a reply and returns the thread as it now stands, or null when it
  /// is gone. The reply and the `updated_at` bump are one transaction, or the
  /// thread sorts behind threads nothing has happened to.
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

  /// Moves a thread's status. Returns the thread, or null when it is gone. The
  /// only mutation here, and it changes nothing anybody wrote.
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

  /// Every thread on [repositoryId], newest activity first, in two statements
  /// whatever the count.
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
            statuses.contains(
              ReviewThreadStatus.fromName(row['status'] as String?),
            ))
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

  /// Every thread with its comments, newest activity first, in two statements.
  List<ReviewThread> all() {
    final rows = _db.query(
      'SELECT * FROM review_threads ORDER BY updated_at DESC, id;',
    );
    final comments = _commentsForThreads([
      for (final row in rows) row['id']! as String,
    ]);
    return [
      for (final row in rows)
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
