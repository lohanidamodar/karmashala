import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/lineage.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'support/store_fixtures.dart';

/// A client's copy answers every question the server's store answers, in the
/// same orders: [SessionRowsIndex] over the rows beside [SessionDao] over the
/// same rows in SQLite. And the imported-history and follow-up rules a copy
/// applies say what the store's reads say.
void main() {
  late AppDatabase db;
  late SessionDao dao;
  late Map<String, Session> rows;
  late SessionRowsIndex index;

  void put(Session row) {
    dao.insert(row);
    rows[row.id] = row;
    index.invalidate();
  }

  setUp(() {
    db = AppDatabase.memory();
    seedWorkspace(db);
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      "VALUES ('r2', 'p1', 'two', 'windows', 'C:\\src\\two', ?);",
      [testTime.toIso8601String()],
    );
    dao = SessionDao(db);
    rows = {};
    index = SessionRowsIndex(() => rows);
    final at = testTime;
    put(
      session(
        id: 'b',
        status: SessionStatus.running,
      ).copyWith(externalSessionId: 'conv-1', paneId: 'pane-1'),
    );
    put(
      session(id: 'a', repositoryId: 'r2', status: SessionStatus.idle).copyWith(
        createdAt: at.add(const Duration(minutes: 1)),
        externalSessionId: 'conv-1',
        paneId: 'pane-1',
        parentSessionId: 'b',
        parentLink: SessionLink.fork,
      ),
    );
    put(
      session(
        id: 'c',
        status: SessionStatus.completed,
      ).copyWith(createdAt: at.add(const Duration(minutes: 2)), archivedAt: at),
    );
    put(
      session(id: 'd', title: 'Typed', status: SessionStatus.failed).copyWith(
        createdAt: at.subtract(const Duration(minutes: 1)),
        externalSessionId: 'conv-2',
        titleByUser: true,
      ),
    );
    put(session(id: 'e').copyWith(createdAt: at, externalSessionId: ''));
  });
  tearDown(() => db.close());

  List<String> ids(Iterable<Session> sessions) => [
    for (final s in sessions) s.id,
  ];

  test('every read agrees with the store, order included', () {
    final SessionReads store = dao;
    final SessionReads copy = index;
    for (final reads in [store, copy]) {
      expect(ids(reads.getAll()), ['d', 'b', 'e', 'a', 'c']);
    }
    expect(
      ids(copy.getByIds(['a', 'b', 'x'])),
      ids(store.getByIds(['a', 'b', 'x'])),
    );
    expect(
      ids(copy.getByPaneIds(['pane-1'])),
      ids(store.getByPaneIds(['pane-1'])),
    );
    expect(copy.paneSessionIds(), store.paneSessionIds());
    expect(copy.repositoryIdsById(), store.repositoryIdsById());
    expect(ids(copy.getClaimingLive()), ids(store.getClaimingLive()));
    expect(
      ids(copy.getAllByExternalSessionId('conv-1')),
      ids(store.getAllByExternalSessionId('conv-1')),
    );
    expect(
      copy.getByExternalSessionId('conv-1')?.id,
      store.getByExternalSessionId('conv-1')?.id,
    );
    expect(copy.heldExternalSessionIds(), store.heldExternalSessionIds());
    expect(
      copy.heldExternalSessionIds(excludingSessionId: 'd'),
      store.heldExternalSessionIds(excludingSessionId: 'd'),
    );
    expect(
      ids(copy.getWaitingForTitleSync()),
      ids(store.getWaitingForTitleSync()),
    );
    expect(ids(copy.getUnattributed()), ids(store.getUnattributed()));
    expect(
      copy.countsByRepositories(['r1', 'r2']),
      store.countsByRepositories(['r1', 'r2']),
    );
    expect(ids(copy.getByRepository('r1')), ids(store.getByRepository('r1')));
    expect(copy.parentOf('a'), store.parentOf('a'));
    expect(ids(copy.childrenOf('b')), ids(store.childrenOf('b')));
    for (final id in ['a', 'b', 'c', 'd', 'e']) {
      expect(copy.getById(id), store.getById(id));
    }
  });

  test('a copy that says its version moved sorts again', () {
    var version = 0;
    final versioned = SessionRowsIndex(() => rows, () => version);
    expect(versioned.getAll(), hasLength(5));
    rows.remove('a');
    expect(versioned.getAll(), hasLength(5), reason: 'kept until told');
    version++;
    expect(versioned.getAll(), hasLength(4));
  });

  test('the imported history a copy shows is what the store lists', () {
    final imported = ImportedSessionDao(db);
    ImportedSession record(String id, String externalId, {DateTime? updated}) =>
        ImportedSession(
          id: id,
          repositoryId: 'r1',
          cli: 'claude-code',
          externalId: externalId,
          environmentId: 'windows',
          filePath: 'f',
          storeHome: 'h',
          isSubagent: false,
          preview: '',
          createdAt: testTime,
          updatedAt: updated,
        );
    // Imported before any row recorded the conversation, so it is kept —
    // and hidden once one does.
    db.execute(
      "UPDATE sessions SET external_session_id = NULL WHERE id = 'b';",
    );
    db.execute(
      "UPDATE sessions SET external_session_id = NULL WHERE id = 'a';",
    );
    for (final r in [
      record('i1', 'conv-1', updated: testTime),
      record('i2', 'conv-3'),
      record('i3', 'conv-4', updated: testTime.add(const Duration(hours: 1))),
    ]) {
      expect(imported.insertIfAbsent(r), isTrue);
    }
    db.execute(
      "UPDATE sessions SET external_session_id = 'conv-1' WHERE id = 'b';",
    );
    final visible = visibleImported(
      imported.everything(),
      dao.heldExternalSessionIds(),
    );
    expect(
      [for (final r in visible) r.id],
      [for (final r in imported.getAll()) r.id],
    );
    expect([for (final r in visible) r.id], ['i3', 'i2']);
    expect(supersedingSessionIdIn(dao, 'conv-1'), 'b');
    expect(
      mayImport(
        record('i4', 'conv-3'),
        existing: imported.getByExternal('claude-code', 'conv-3'),
        superseded: false,
      ),
      isFalse,
    );
  });

  test('the open follow-ups a copy lists are the store\'s, newest first', () {
    final followUps = FollowUpDao(db);
    FollowUp raised(String sessionId, int minutes) => followUps.raise(
      FollowUp(
        sessionId: sessionId,
        reason: FollowUpReason.endedInFailure,
        ending: SessionEnding.failed,
        raisedAt: testTime.add(Duration(minutes: minutes)),
      ),
    )!;
    raised('a', 1);
    final second = raised('b', 2);
    raised('c', 0);
    followUps.resolve(
      second.id!,
      resolution: FollowUpResolution.dismissed,
      at: testTime,
    );
    expect(
      [for (final f in openFollowUps(followUps.all())) f.id],
      [for (final f in followUps.open()) f.id],
    );
    expect(openFollowUps(followUps.all(), limit: 1), hasLength(1));
    expect({
      for (final f in followUps.all()) f.endingMark,
    }, followUps.raisedEndings());
  });

  test('runsOnThisMachine: the directory first, then the checkout; SSH and '
      'the unknown are not this machine', () {
    EnvironmentKind? kind(String id) => switch (id) {
      'windows' => EnvironmentKind.windowsNative,
      'ssh:h' => EnvironmentKind.ssh,
      _ => null,
    };
    bool runs(Session s) => runsOnThisMachine(
      s,
      environmentOfRepository: (id) => id == 'r1' ? 'windows' : null,
      kindOf: kind,
    );
    expect(runs(session()), isTrue);
    expect(
      runs(
        session(
          workingDirectory: const EnvironmentPath(
            environmentId: 'ssh:h',
            path: '/src',
          ),
        ),
      ),
      isFalse,
    );
    expect(runs(session(repositoryId: 'rX')), isFalse);
    expect(sessionRunsOnThisMachine(db, session()), isTrue);
  });
}
