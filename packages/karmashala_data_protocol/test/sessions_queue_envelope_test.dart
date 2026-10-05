import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

/// A session's message queue crosses the wire whole: the requests that list,
/// edit and cancel it, a send's queued answer, and the change that tells it.
void main() {
  Map<String, Object?> wire(Object? json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();
  Object? roundTrip(Object? json) => jsonDecode(jsonEncode(json));

  final t0 = DateTime.utc(2026, 10, 3, 12);
  final queued = QueuedMessage(
    id: 'q1',
    sessionId: 's1',
    seq: 3,
    text: 'Then run the tests',
    state: QueuedMessageState.queued,
    origin: QueuedMessageOrigin.mcp,
    originId: 'caller',
    createdAt: t0,
    updatedAt: t0,
    requestId: 'r1',
  );
  final failed = QueuedMessage(
    id: 'q0',
    sessionId: 's1',
    seq: 2,
    text: 'Fix it',
    state: QueuedMessageState.failed,
    origin: QueuedMessageOrigin.app,
    createdAt: t0,
    updatedAt: t0,
    error: 'the server stopped while it was being delivered',
  );

  test('sessions.queue.list names the session and reads every message', () {
    const request = SessionQueueList('s1');
    final read = DataRequest.fromJson(
      request.kind,
      wire(request.argumentsToJson()),
    );
    expect(read, isA<SessionQueueList>());
    read as SessionQueueList;
    expect(read.sessionId, 's1');
    expect(read.kind, 'sessions.queue.list');
    expect(
      request.resultFromJson(roundTrip(request.resultToJson([failed, queued]))),
      [failed, queued],
    );
  });

  test('sessions.queue.edit and .cancel carry the message they act on', () {
    const edit = SessionQueueEdit(sessionId: 's1', id: 'q1', text: 'Now');
    final readEdit =
        DataRequest.fromJson(edit.kind, wire(edit.argumentsToJson()))
            as SessionQueueEdit;
    expect(
      (readEdit.sessionId, readEdit.id, readEdit.text),
      ('s1', 'q1', 'Now'),
    );
    expect(edit.resultFromJson(roundTrip(edit.resultToJson(queued))), queued);

    const cancel = SessionQueueCancel(sessionId: 's1', id: 'q1');
    final readCancel =
        DataRequest.fromJson(cancel.kind, wire(cancel.argumentsToJson()))
            as SessionQueueCancel;
    expect((readCancel.sessionId, readCancel.id), ('s1', 'q1'));
    expect(readCancel.requestId, isNull);
  });

  test('a queued send answers its row and place; an older answer has none', () {
    const sent = SessionSent(
      sent: true,
      via: SessionSent.queuedVia,
      queuedId: 'q1',
      position: 2,
    );
    const request = SessionSend(sessionId: 's1', text: 'x');
    final read = request.resultFromJson(roundTrip(request.resultToJson(sent)));
    expect(read.queued, isTrue);
    expect((read.queuedId, read.position, read.via), ('q1', 2, 'queued'));

    final older = request.resultFromJson({'sent': true, 'via': 'readBack'});
    expect(older.queued, isFalse);
    expect(older.position, isNull);
    expect(request.resultToJson(older), isNot(contains('queuedId')));
  });

  test('sessionQueueChanged carries the whole open list', () {
    final change = SessionQueueChanged(
      sessionId: 's1',
      messages: [failed, queued],
    );
    final read = DataChange.fromJson(wire(change.toJson()));
    expect(read, isA<SessionQueueChanged>());
    read as SessionQueueChanged;
    expect(read.sessionId, 's1');
    expect(read.messages, [failed, queued]);
  });

  test('sessions.queue.sendNext names the session and reads the message', () {
    const request = SessionQueueSendNext('s1');
    final read =
        DataRequest.fromJson(request.kind, wire(request.argumentsToJson()))
            as SessionQueueSendNext;
    expect((read.sessionId, read.kind), ('s1', 'sessions.queue.sendNext'));
    expect(
      request.resultFromJson(roundTrip(request.resultToJson(queued))),
      queued,
    );
  });

  test('sessions.queue.sendNow names the session and the message', () {
    const request = SessionQueueSendNow(sessionId: 's1', id: 'q1');
    final read =
        DataRequest.fromJson(request.kind, wire(request.argumentsToJson()))
            as SessionQueueSendNow;
    expect(
      (read.sessionId, read.id, read.kind),
      ('s1', 'q1', 'sessions.queue.sendNow'),
    );
    expect(
      request.resultFromJson(roundTrip(request.resultToJson(queued))),
      queued,
    );
  });

  test('sessions.queue.sendAll names the session and reads the messages', () {
    const request = SessionQueueSendAll('s1');
    final read =
        DataRequest.fromJson(request.kind, wire(request.argumentsToJson()))
            as SessionQueueSendAll;
    expect((read.sessionId, read.kind), ('s1', 'sessions.queue.sendAll'));
    expect(request.resultFromJson(roundTrip(request.resultToJson([queued]))), [
      queued,
    ]);
  });

  test('sessions.queue.pause carries whether to pause', () {
    for (final paused in [true, false]) {
      final request = SessionQueuePause(sessionId: 's1', paused: paused);
      final read =
          DataRequest.fromJson(request.kind, wire(request.argumentsToJson()))
              as SessionQueuePause;
      expect(
        (read.sessionId, read.paused, read.kind),
        ('s1', paused, 'sessions.queue.pause'),
      );
      expect(
        request.resultFromJson(roundTrip(request.resultToJson([queued]))),
        [queued],
      );
    }
  });

  test('a hold rides on a queued message; one this build does not know, or '
      'none, reads as none', () {
    final held = queued.copyWith(
      hold: QueueHold(QueueHoldKind.limit, until: t0),
    );
    expect(QueuedMessage.fromJson(wire(held.toJson())), held);
    expect(queued.toJson().containsKey('hold'), isFalse);
    final newer = wire(held.toJson())..['hold'] = {'kind': 'somethingNew'};
    expect(QueuedMessage.fromJson(newer).hold, isNull);
    final automation = QueuedMessageOrigin.fromName('automation');
    expect(automation, QueuedMessageOrigin.automation);
  });
}
