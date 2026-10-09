import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../support/store_fixtures.dart';

/// `session_queued_messages`: appended in order, moved only from the state
/// it is in, edited only while queued, and a delivery a stop interrupted is
/// failed rather than resent.
void main() {
  late AppDatabase db;
  late SessionQueueDao dao;
  final t0 = DateTime.utc(2026, 10, 3, 12);

  setUp(() {
    db = AppDatabase.memory();
    seedWorkspace(db);
    SessionDao(db).insert(session());
    dao = SessionQueueDao(db);
  });
  tearDown(() => db.close());

  QueuedMessage add(String id, String text, {String? requestId}) => dao.enqueue(
    id: id,
    sessionId: 's1',
    text: text,
    origin: QueuedMessageOrigin.mcp,
    originId: 'caller',
    requestId: requestId,
    now: t0,
  );

  test('messages queue in order and read back whole', () {
    final first = add('q1', 'one', requestId: 'r1');
    add('q2', 'two');
    expect(first.seq, 1);
    expect(dao.open('s1').map((m) => (m.id, m.seq)), [('q1', 1), ('q2', 2)]);
    expect(dao.getById('q1'), first);
    expect(dao.byRequest('s1', 'r1')?.id, 'q1');
    expect(dao.head('s1')?.id, 'q1');
    expect(dao.positionOf('s1', 2), 2);
    expect(dao.hasWaiting('s1'), isTrue);
    expect(dao.sessionsWithQueued(), ['s1']);
  });

  test('waiting from some origins counts only theirs, and any on its way', () {
    const person = {QueuedMessageOrigin.app, QueuedMessageOrigin.device};
    add('q1', 'from an agent');
    expect(dao.hasWaitingFrom('s1', person), isFalse);
    dao.transition(
      'q1',
      from: QueuedMessageState.queued,
      to: QueuedMessageState.delivering,
      now: t0,
    );
    expect(dao.hasWaitingFrom('s1', person), isTrue);
    dao.transition(
      'q1',
      from: QueuedMessageState.delivering,
      to: QueuedMessageState.delivered,
      now: t0,
    );
    dao.enqueue(
      id: 'q2',
      sessionId: 's1',
      text: 'from the phone',
      origin: QueuedMessageOrigin.device,
      now: t0,
    );
    expect(dao.hasWaitingFrom('s1', person), isTrue);
  });

  test('a cancel records who cancelled it', () {
    add('q1', 'one');
    expect(
      dao.transition(
        'q1',
        from: QueuedMessageState.queued,
        to: QueuedMessageState.cancelled,
        now: t0,
        cancelledBy: 'device:phone-1',
      ),
      isTrue,
    );
    final cancelled = dao.getById('q1')!;
    expect(cancelled.cancelledBy, 'device:phone-1');
    expect(cancelled.error, isNull);
    expect(add('q2', 'two').cancelledBy, isNull);
  });

  test('a move is guarded on the state it leaves', () {
    add('q1', 'one');
    expect(
      dao.transition(
        'q1',
        from: QueuedMessageState.queued,
        to: QueuedMessageState.delivering,
        now: t0,
      ),
      isTrue,
    );
    expect(
      dao.transition(
        'q1',
        from: QueuedMessageState.queued,
        to: QueuedMessageState.delivering,
        now: t0,
      ),
      isFalse,
    );
    final later = t0.add(const Duration(seconds: 3));
    dao.transition(
      'q1',
      from: QueuedMessageState.delivering,
      to: QueuedMessageState.delivered,
      now: later,
    );
    final delivered = dao.getById('q1')!;
    expect(delivered.state, QueuedMessageState.delivered);
    expect(delivered.deliveredAt, later);
    expect(dao.open('s1'), isEmpty);
    expect(dao.hasWaiting('s1'), isFalse);
  });

  test('a queued message moves ahead of the rest; one on its way does not', () {
    add('q1', 'one');
    add('q2', 'two');
    add('q3', 'three');
    expect(dao.moveToFront('q3'), isTrue);
    expect(dao.open('s1').map((m) => m.id), ['q3', 'q1', 'q2']);
    expect(dao.head('s1')?.id, 'q3');
    expect(dao.positionOf('s1', dao.getById('q1')!.seq), 2);
    // A message added after still goes last.
    add('q4', 'four');
    expect(dao.open('s1').map((m) => m.id), ['q3', 'q1', 'q2', 'q4']);

    dao.transition(
      'q2',
      from: QueuedMessageState.queued,
      to: QueuedMessageState.delivering,
      now: t0,
    );
    expect(dao.moveToFront('q2'), isFalse);
    expect(dao.moveToFront('missing'), isFalse);
  });

  test('text is edited only while queued', () {
    add('q1', 'one');
    expect(dao.editText('q1', 'uno', now: t0), isTrue);
    expect(dao.getById('q1')!.text, 'uno');
    dao.transition(
      'q1',
      from: QueuedMessageState.queued,
      to: QueuedMessageState.cancelled,
      now: t0,
    );
    expect(dao.editText('q1', 'eins', now: t0), isFalse);
    expect(dao.getById('q1')!.text, 'uno');
  });

  test('a row left delivering is failed with its reason, never queued '
      'again', () {
    add('q1', 'one');
    add('q2', 'two');
    dao.transition(
      'q1',
      from: QueuedMessageState.queued,
      to: QueuedMessageState.delivering,
      now: t0,
    );
    expect(dao.failInterrupted(now: t0, error: 'stopped'), {'s1'});
    final failed = dao.getById('q1')!;
    expect(failed.state, QueuedMessageState.failed);
    expect(failed.error, 'stopped');
    expect(dao.head('s1')?.id, 'q2');
    expect(dao.open('s1').map((m) => m.id), ['q1', 'q2']);
  });
  group('a person\'s message goes before what other sessions queued', () {
    QueuedMessage person(String id) => dao.enqueue(
      id: id,
      sessionId: 's1',
      text: id,
      origin: QueuedMessageOrigin.app,
      now: t0,
    );

    test('it jumps ahead of queued peer messages', () {
      add('p1', 'from the parent');
      add('p2', 'from the parent again');
      final mine = person('me1');
      expect(dao.head('s1')?.id, 'me1');
      expect(dao.open('s1').map((m) => m.id), ['me1', 'p1', 'p2']);
      expect(dao.positionOf('s1', mine.seq), 1);
    });

    test("the person's own order is kept, peers after them all", () {
      add('p1', 'peer');
      person('me1');
      add('p2', 'peer, later');
      person('me2');
      expect(dao.open('s1').map((m) => m.id), ['me1', 'me2', 'p1', 'p2']);
    });

    test('a phone is the person too; a message on its way is not passed', () {
      add('p1', 'peer');
      dao.transition(
        'p1',
        from: QueuedMessageState.queued,
        to: QueuedMessageState.delivering,
        now: t0,
      );
      add('p2', 'peer');
      dao.enqueue(
        id: 'phone',
        sessionId: 's1',
        text: 'from the phone',
        origin: QueuedMessageOrigin.device,
        now: t0,
      );
      expect(dao.open('s1').map((m) => m.id), ['p1', 'phone', 'p2']);
    });

    test('a cancelled peer message never comes up again', () {
      add('p1', 'peer');
      person('me1');
      expect(
        dao.transition(
          'p1',
          from: QueuedMessageState.queued,
          to: QueuedMessageState.cancelled,
          now: t0,
          cancelledBy: 'the person',
        ),
        isTrue,
      );
      expect(dao.head('s1')?.id, 'me1');
      dao.transition(
        'me1',
        from: QueuedMessageState.queued,
        to: QueuedMessageState.delivered,
        now: t0,
      );
      expect(dao.head('s1'), isNull);
    });
  });
}
