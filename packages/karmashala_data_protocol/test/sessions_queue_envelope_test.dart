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
}
