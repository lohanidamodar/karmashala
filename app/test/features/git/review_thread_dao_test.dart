import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/git/data/review_thread_dao.dart';
import 'package:karmashala_git/git.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

void main() {
  late AppDatabase db;
  late ReviewThreadDao dao;
  late FakeDataServer server;

  setUp(() {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    dao = ReviewThreadDao(db);
  });
  tearDown(() => db.close());

  ReviewThread open({
    String id = 't-1',
    String path = 'lib/a.dart',
    String sha = 'sha-one',
    int? line = 4,
    ReviewThreadStatus status = ReviewThreadStatus.open,
    String body = 'This is wrong.',
    DateTime? at,
  }) => dao.open(
    id: id,
    repositoryId: 'r1',
    anchor: ReviewAnchor(
      path: path,
      blobSha: sha,
      startLine: line,
      endLine: line,
      excerpt: 'return null;',
    ),
    status: status,
    author: 'the user',
    authorKind: ReviewAuthorKind.user,
    body: body,
    now: at ?? testTime,
  );

  test('a thread is never created without its first comment', () {
    final thread = open();
    expect(thread.comments, hasLength(1));
    expect(thread.comments.single.sequence, 1);
    expect(thread.body, 'This is wrong.');
    // And nothing in the schema left a thread behind with no comment.
    expect(
      db.query('SELECT COUNT(*) AS n FROM review_thread_comments;').first['n'],
      1,
    );
  });

  test('replies append in order and are attributed', () {
    open();
    dao.reply(
      threadId: 't-1',
      author: 'an agent in session s1',
      authorKind: ReviewAuthorKind.agent,
      body: 'Fixed — it returns the default now.',
      now: testTime.add(const Duration(minutes: 1)),
    );
    final thread = dao.getById('t-1')!;
    expect(thread.comments.map((c) => c.sequence), [1, 2]);
    expect(thread.replies.single.author, 'an agent in session s1');
    expect(thread.replies.single.authorKind, ReviewAuthorKind.agent);
    // The thread's own timestamp moved with it, which is what the list orders
    // on — a reply that did not bump it would sort behind untouched threads.
    expect(thread.updatedAt.isAfter(thread.createdAt), isTrue);
  });

  test('two writers cannot claim the same position in one thread', () {
    open();
    void insert(int sequence) => db.execute(
      'INSERT INTO review_thread_comments (thread_id, sequence, author, '
      'author_kind, body, created_at) VALUES (?, ?, ?, ?, ?, ?);',
      ['t-1', sequence, 'x', 'user', 'y', 'z'],
    );
    // Position 1 is taken by the opening comment.
    expect(() => insert(1), throwsA(isA<SqliteException>()));
    insert(2);
  });

  test('status moves, and moves back, without touching what was written', () {
    open();
    dao.setStatus('t-1', ReviewThreadStatus.dismissed, now: testTime);
    expect(dao.getById('t-1')!.status, ReviewThreadStatus.dismissed);
    dao.setStatus('t-1', ReviewThreadStatus.shouldFix, now: testTime);

    final thread = dao.getById('t-1')!;
    expect(thread.status, ReviewThreadStatus.shouldFix);
    expect(thread.comments, hasLength(1));
    expect(thread.body, 'This is wrong.');
    expect(thread.anchor.blobSha, 'sha-one');
    expect(thread.anchor.startLine, 4);
  });

  test('an unrecognised status reads as unrecognised, not as open', () {
    open();
    db.execute("UPDATE review_threads SET status = 'escalated';");
    // Folding it into `open` would put a thread somebody had already dealt
    // with back in front of them as untriaged work.
    expect(dao.getById('t-1')!.status, ReviewThreadStatus.unrecognised);
  });

  test('a repository going away takes its threads and comments with it', () {
    open();
    dao.reply(
      threadId: 't-1',
      author: 'the user',
      authorKind: ReviewAuthorKind.user,
      body: 'still wrong',
      now: testTime,
    );
    server.repositoryRows.delete('r1');
    expect(db.query('SELECT * FROM review_threads;'), isEmpty);
    expect(db.query('SELECT * FROM review_thread_comments;'), isEmpty);
  });

  test('replying to a thread that is gone reports it rather than throwing', () {
    expect(
      dao.reply(
        threadId: 'nope',
        author: 'the user',
        authorKind: ReviewAuthorKind.user,
        body: 'x',
        now: testTime,
      ),
      isNull,
    );
    expect(
      dao.setStatus('nope', ReviewThreadStatus.resolved, now: testTime),
      isNull,
    );
  });

  test('a repository reads newest activity first, filtered by path', () {
    open(id: 't-1', path: 'lib/a.dart', at: testTime);
    open(
      id: 't-2',
      path: 'lib/b.dart',
      at: testTime.add(const Duration(minutes: 2)),
    );
    expect(dao.forRepository('r1').map((t) => t.id), ['t-2', 't-1']);
    expect(dao.forRepository('r1', path: 'lib/a.dart').map((t) => t.id), [
      't-1',
    ]);
  });
}
