import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_host/src/sessions/session_detach.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// **A detached sub-session is a top-level session**: its row loses the link
/// and nothing else, its delegation row goes, every client is told, and the
/// parent's thread is handed its line. Refused for a session with no parent,
/// one that is gone, and — asked by a parent — another session's child.
void main() {
  final t0 = DateTime.utc(2026, 10, 8, 9);

  late AppDatabase database;
  late List<String> announced;
  late List<(String, String)> notes;
  late SessionDetacher detacher;

  void insert(String id, {String? parent, SessionLink? link}) =>
      SessionDao(database).insert(
        Session(
          id: id,
          repositoryId: 'r1',
          agentInstallationId: 'a1',
          title: 'Session $id',
          useWorktree: true,
          worktree: const EnvironmentPath(
            environmentId: 'local',
            path: '/w/child',
          ),
          status: SessionStatus.running,
          createdAt: t0,
          parentSessionId: parent,
          parentLink: link,
        ),
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
    insert('child', parent: 'parent', link: SessionLink.spawn);
    insert('grandchild', parent: 'child', link: SessionLink.spawn);
    SessionDelegationDao(database).put(
      SessionDelegation(
        childSessionId: 'child',
        parentSessionId: 'parent',
        title: 'Session child',
        agent: 'Claude Code',
        delegatedAt: t0,
        turn: 1,
        turnStartedAt: t0,
      ),
    );
    announced = [];
    notes = [];
    detacher = SessionDetacher(
      database: database,
      announce: announced.addAll,
      note: (parentId, child) async =>
          notes.add((parentId, detachedNote(child.title))),
    );
  });

  tearDown(() => database.close());

  test('the child becomes top-level, keeping its worktree, title and '
      'children; its delegation goes and its parent gets a line', () async {
    final before = SessionDao(database).getById('child')!;
    final after = await detacher.detach('child');

    expect(after.parentSessionId, isNull);
    expect(after.parentLink, isNull);
    expect(after.worktree, before.worktree);
    expect(after.title, before.title);
    expect(after.status, before.status);
    expect(SessionDao(database).childrenOf('parent'), isEmpty);
    expect(SessionDao(database).parentOf('grandchild'), 'child');
    expect(SessionDelegationDao(database).byChild('child'), isNull);
    expect(announced, ['child']);
    expect(notes, [('parent', '"Session child" was detached')]);
  });

  test(
    'it leaves the depth count: its own children sit one level up',
    () async {
      final dao = SessionDao(database);
      expect(SessionDepth.forChildOf('grandchild', dao.parentOf).depth, 3);
      await detacher.detach('child');
      expect(SessionDepth.forChildOf('grandchild', dao.parentOf).depth, 2);
    },
  );

  test('a parent asking may take only its own child', () async {
    insert('other');
    await expectLater(
      detacher.detach('child', by: 'other'),
      throwsA(isA<DataRefused>()),
    );
    expect(SessionDao(database).parentOf('child'), 'parent');
    expect(SessionDelegationDao(database).byChild('child'), isNotNull);
    await detacher.detach('child', by: 'parent');
    expect(SessionDao(database).parentOf('child'), isNull);
  });

  test('a session with no parent, or none at all, is refused', () async {
    await expectLater(
      detacher.detach('parent'),
      throwsA(
        isA<DataRefused>().having(
          (e) => e.message,
          'message',
          contains('no parent'),
        ),
      ),
    );
    await expectLater(detacher.detach('gone'), throwsA(isA<DataRefused>()));
    expect(announced, isEmpty);
    expect(notes, isEmpty);
  });

  test('a note that fails leaves the detach standing', () async {
    final failing = SessionDetacher(
      database: database,
      announce: announced.addAll,
      note: (_, _) async => throw StateError('no board'),
    );
    final after = await failing.detach('child');
    expect(after.parentSessionId, isNull);
    expect(announced, ['child']);
  });
}
