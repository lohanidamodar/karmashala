import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/follow_ups/data/follow_up_dao.dart';
import 'package:karmashala/src/features/follow_ups/domain/follow_up.dart';
import 'package:karmashala/src/features/follow_ups/domain/session_ending.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 1, 10);

  late AppDatabase db;
  late FollowUpDao dao;

  FollowUp pending({
    String sessionId = 's1',
    FollowUpReason reason = FollowUpReason.endedInFailure,
    SessionEnding ending = SessionEnding.failed,
    String? summary,
    DateTime? at,
  }) => FollowUp(
    sessionId: sessionId,
    reason: reason,
    ending: ending,
    summary: summary,
    raisedAt: at ?? t0,
  );

  setUp(() {
    db = AppDatabase.memory();
    dao = FollowUpDao(db);
  });
  tearDown(() => db.close());

  test('raising one gives it an id and leaves it open', () {
    final raised = dao.raise(pending(summary: 'The agent stopped in error.'))!;
    expect(raised.id, isNotNull);
    expect(raised.isOpen, isTrue);
    expect(raised.summary, 'The agent stopped in error.');
    expect(dao.open(), [raised]);
  });

  test('re-noticing the same ended session raises nothing new', () {
    // The observer runs on every session-revision bump and re-reads the same
    // ended rows. Without this a workspace would accumulate one identical
    // notice per bump — which is how a work queue becomes a log.
    final first = dao.raise(pending())!;
    expect(dao.raise(pending()), isNull);
    expect(dao.raise(pending(reason: FollowUpReason.verificationAbandoned)),
        isNull);
    expect(dao.open(), [first]);
  });

  test('a resolved follow-up frees the session to raise another', () {
    final first = dao.raise(pending())!;
    dao.resolve(
      first.id!,
      resolution: FollowUpResolution.dismissed,
      at: t0.add(const Duration(hours: 1)),
    );
    expect(dao.open(), isEmpty);

    final second = dao.raise(pending(at: t0.add(const Duration(hours: 2))))!;
    expect(second.id, isNot(first.id));
    expect(dao.open().single.id, second.id);
  });

  test('resolving records which way it went', () {
    final one = dao.raise(pending())!;
    dao.resolve(
      one.id!,
      resolution: FollowUpResolution.carriedForward,
      at: t0.add(const Duration(minutes: 5)),
    );
    final rows = db.query('SELECT * FROM session_follow_ups;');
    expect(rows.single['resolution'], 'carriedForward');
    expect(rows.single['resolved_at'], isNotNull);
  });

  test('open() is newest first and bounded', () {
    for (var i = 0; i < 5; i++) {
      dao.raise(
        pending(sessionId: 's$i', at: t0.add(Duration(minutes: i))),
      );
    }
    expect(
      dao.open().map((f) => f.sessionId),
      ['s4', 's3', 's2', 's1', 's0'],
    );
    expect(dao.open(limit: 2).map((f) => f.sessionId), ['s4', 's3']);
  });

  test('a follow-up outlives the app that raised it', () {
    // The whole reason this is a table and not a field on an in-memory inbox:
    // a session that failed at six must still be waiting at nine.
    dao.raise(pending(summary: 'Stopped in error.'));

    // A second DAO over the same connection is the closest an in-memory
    // database gets to a restart: nothing is cached in Dart.
    final reopened = FollowUpDao(db).open();
    expect(reopened.single.summary, 'Stopped in error.');
    expect(reopened.single.isOpen, isTrue);
  });

  test('an unknown reason or ending reads as unrecognised, never as a guess', () {
    db.execute(
      'INSERT INTO session_follow_ups '
      '(session_id, reason, ending, raised_at) VALUES (?, ?, ?, ?);',
      ['s9', 'somethingNewer', 'alsoNewer', '2026-09-01T10:00:00.000Z'],
    );
    final row = dao.open().single;
    expect(row.reason, FollowUpReason.unrecognised);
    expect(row.ending, SessionEnding.unrecognised);
  });

  test('resolving twice is refused rather than silently rewriting', () {
    final one = dao.raise(pending())!;
    dao.resolve(
      one.id!,
      resolution: FollowUpResolution.dismissed,
      at: t0.add(const Duration(minutes: 1)),
    );
    // Already closed: the second call changes nothing, so the record of *when*
    // and *how* it was closed the first time survives.
    dao.resolve(
      one.id!,
      resolution: FollowUpResolution.carriedForward,
      at: t0.add(const Duration(minutes: 9)),
    );
    final rows = db.query('SELECT * FROM session_follow_ups;');
    expect(rows.single['resolution'], 'dismissed');
  });

  test('the schema, not the DAO, is what stops a second open row', () {
    dao.raise(pending());
    expect(
      () => db.execute(
        'INSERT INTO session_follow_ups '
        '(session_id, reason, ending, raised_at) VALUES (?, ?, ?, ?);',
        ['s1', 'endedInFailure', 'failed', '2026-09-01T11:00:00.000Z'],
      ),
      throwsA(isA<SqliteException>()),
    );
  });
}
