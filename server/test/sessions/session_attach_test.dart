import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_host/src/sessions/session_attach.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// **An attached session is the parent's child**: its row gains the link and
/// nothing else, a `final` delegation is recorded by its follows, every
/// client is told, and the parent's thread is handed its line. Refused for a
/// loop, past the depth cap, an archived session, one already under a parent,
/// and a parent nothing runs that has nothing to resume.
void main() {
  final t0 = DateTime.utc(2026, 10, 8, 9);

  late AppDatabase database;
  late List<String> announced;
  late List<(String, String)> notes;
  late Set<String> live;
  late SessionAttacher attacher;

  void insert(
    String id, {
    String? parent,
    DateTime? archivedAt,
    String? conversation = 'conv',
  }) => SessionDao(database).insert(
    Session(
      id: id,
      repositoryId: 'r1',
      agentInstallationId: 'a1',
      title: 'Session $id',
      useWorktree: false,
      status: SessionStatus.running,
      createdAt: t0,
      externalSessionId: conversation,
      parentSessionId: parent,
      parentLink: parent == null ? null : SessionLink.spawn,
      archivedAt: archivedAt,
    ),
  );

  Matcher refused(String words) => throwsA(
    isA<DataRefused>().having((e) => e.message, 'message', contains(words)),
  );

  setUp(() {
    database = AppDatabase.memory();
    database.execute('PRAGMA foreign_keys = OFF;');
    database.execute(
      'INSERT INTO agent_installations (id, agent_kind, environment_id, '
      'executable_path, created_at, executable_by_user) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      ['a1', AgentIds.claudeCode, 'local', '/bin/claude', '$t0', 1],
    );
    insert('parent');
    insert('loose');
    announced = [];
    notes = [];
    live = {'parent', 'loose'};
    attacher = SessionAttacher(
      database: database,
      announce: announced.addAll,
      agentOf: (_) => 'Claude Code',
      isLive: live.contains,
      note: (parentId, child) async =>
          notes.add((parentId, attachedNote(child.title))),
      now: () => t0,
    );
  });

  tearDown(() => database.close());

  test(
    'the session becomes a spawned child, and the parent gets a line',
    () async {
      final before = SessionDao(database).getById('loose')!;
      final after = await attacher.attach('loose', 'parent');

      expect(after.parentSessionId, 'parent');
      expect(after.parentLink, SessionLink.spawn);
      expect(after.title, before.title);
      expect(after.status, before.status);
      expect(SessionDao(database).childrenOf('parent').single.id, 'loose');
      expect(announced, ['loose']);
      expect(notes, [('parent', '"Session loose" was attached')]);
    },
  );

  test(
    'a session under its own sub-session would loop, and is refused',
    () async {
      insert('kid', parent: 'loose');
      await expectLater(attacher.attach('loose', 'kid'), refused('loop'));
      await expectLater(attacher.attach('loose', 'loose'), refused('loop'));
      expect(SessionDao(database).parentOf('loose'), isNull);
      expect(announced, isEmpty);
    },
  );

  test('past the depth cap is refused, its own sub-sessions counted', () async {
    insert('mid', parent: 'parent');
    insert('deep', parent: 'mid');
    live.addAll({'mid', 'deep'});
    // Level 3 under "deep".
    await expectLater(attacher.attach('loose', 'deep'), refused('levels deep'));
    // Level 2 under "mid", but its own child would be level 3.
    insert('kid', parent: 'loose');
    await expectLater(attacher.attach('loose', 'mid'), refused('own sub'));
    expect(SessionDao(database).parentOf('loose'), isNull);
  });

  test('an archived session, or an archived parent, is refused', () async {
    insert('shelved', archivedAt: t0);
    await expectLater(
      attacher.attach('shelved', 'parent'),
      refused('archived'),
    );
    await expectLater(attacher.attach('loose', 'shelved'), refused('archived'));
    expect(notes, isEmpty);
  });

  test(
    'a session already under a parent is refused: detach it first',
    () async {
      insert('taken', parent: 'parent');
      insert('other');
      await expectLater(
        attacher.attach('taken', 'other'),
        refused('Detach it'),
      );
      expect(SessionDao(database).parentOf('taken'), 'parent');
    },
  );

  test('a parent nothing runs is taken while it can be resumed', () async {
    insert('asleep');
    insert('blank', conversation: null);
    expect(
      (await attacher.attach('loose', 'asleep')).parentSessionId,
      'asleep',
    );
    insert('loose2');
    await expectLater(attacher.attach('loose2', 'blank'), refused('resume'));
  });

  test('a session that is gone is refused', () async {
    await expectLater(
      attacher.attach('gone', 'parent'),
      throwsA(isA<DataRefused>()),
    );
    await expectLater(
      attacher.attach('loose', 'gone'),
      throwsA(isA<DataRefused>()),
    );
  });

  test('a note that fails leaves the attach standing', () async {
    final failing = SessionAttacher(
      database: database,
      announce: announced.addAll,
      agentOf: (_) => 'Claude Code',
      note: (_, _) async => throw StateError('no board'),
    );
    final after = await failing.attach('loose', 'parent');
    expect(after.parentSessionId, 'parent');
    expect(announced, ['loose']);
  });
}
