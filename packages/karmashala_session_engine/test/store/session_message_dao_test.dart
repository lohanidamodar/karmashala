import 'dart:convert';

import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import '../support/store_fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionMessageDao dao;
  var clock = testTime;

  setUp(() {
    db = AppDatabase.memory();
    seedWorkspace(db);
    SessionDao(db).insert(session());
    clock = testTime;
    dao = SessionMessageDao(db, now: () => clock);
  });
  tearDown(() => db.close());

  SessionMessage message({
    String id = 'm1',
    String sessionId = 's1',
    SessionMessageRole role = SessionMessageRole.agent,
    String text = 'hi',
    String? toolJson,
    String? planJson,
  }) => SessionMessage(
    id: id,
    sessionId: sessionId,
    role: role,
    text: text,
    toolJson: toolJson,
    planJson: planJson,
    createdAt: testTime,
    updatedAt: testTime,
  );

  test('append assigns contiguous ordinals and a rising revision', () {
    final a = dao.append(message(id: 'a', role: SessionMessageRole.user));
    final b = dao.append(message(id: 'b'));
    final c = dao.append(message(id: 'c', role: SessionMessageRole.tool));
    expect([a.ordinal, b.ordinal, c.ordinal], [0, 1, 2]);
    expect([a.revision, b.revision, c.revision], [1, 2, 3]);
    expect(dao.latestRevision('s1'), 3);
    expect(dao.countForSession('s1'), 3);
    expect(dao.getById('c')?.role, SessionMessageRole.tool);
  });

  test('ordinals and revisions are per session', () {
    SessionDao(db).insert(session(id: 's2', title: 'Second'));
    dao.append(message(id: 'a'));
    dao.append(message(id: 'b'));
    final other = dao.append(message(id: 'c', sessionId: 's2'));
    expect(other.ordinal, 0);
    expect(other.revision, 1);
    expect(dao.latestRevision('s2'), 1);
    expect(dao.latestRevision('none'), 0);
  });

  test('patch appends text and thinking, and bumps the revision', () {
    dao.append(message(id: 'a', text: 'Hel'));
    dao.append(message(id: 'b'));
    clock = testTime.add(const Duration(seconds: 5));
    final patched = dao.patch('a', appendText: 'lo', appendThinking: 'why');
    expect(patched?.text, 'Hello');
    expect(patched?.thinking, 'why');
    expect(patched?.revision, 3);
    expect(patched?.updatedAt, clock);
    expect(dao.getById('a')?.text, 'Hello');
    expect(dao.latestRevision('s1'), 3);
    // Ordinals do not move with a patch.
    expect(dao.getById('a')?.ordinal, 0);
  });

  test('patch replaces text when told to, and writes the tool status', () {
    dao.append(
      message(
        id: 't',
        role: SessionMessageRole.tool,
        toolJson: jsonEncode({'toolCallId': 'c1', 'status': 'pending'}),
      ),
    );
    final patched = dao.patch('t', text: 'done', status: 'completed');
    expect(patched?.text, 'done');
    expect(jsonDecode(patched!.toolJson!), {
      'toolCallId': 'c1',
      'status': 'completed',
    });
    // A status on a row without tool JSON creates the object.
    dao.append(message(id: 'p'));
    expect(jsonDecode(dao.patch('p', status: 'failed')!.toolJson!), {
      'status': 'failed',
    });
    expect(dao.patch('missing', text: 'x'), isNull);
  });

  test('listAfter pages by ordinal and listSince by revision', () {
    for (final id in ['a', 'b', 'c', 'd']) {
      dao.append(message(id: id));
    }
    expect(dao.listAfter('s1').map((m) => m.id), ['a', 'b', 'c', 'd']);
    expect(dao.listAfter('s1', afterOrdinal: 1).map((m) => m.id), ['c', 'd']);
    expect(dao.listAfter('s1', afterOrdinal: 0, limit: 2).map((m) => m.id), [
      'b',
      'c',
    ]);
    dao.patch('a', appendText: '!');
    // Revision 5 is the patch; rows at or below revision 3 are not sent.
    expect(dao.listSince('s1', 3).map((m) => m.id), ['a', 'd']);
    expect(dao.listSince('s1', 5), isEmpty);
  });

  test('deleteForSession and the session cascade both empty the table', () {
    SessionDao(db).insert(session(id: 's2', title: 'Second'));
    dao.append(message(id: 'a'));
    dao.append(message(id: 'b', sessionId: 's2'));
    dao.deleteForSession('s2');
    expect(dao.countForSession('s2'), 0);
    expect(dao.countForSession('s1'), 1);
    SessionDao(db).delete('s1');
    expect(dao.countForSession('s1'), 0);
  });
}
