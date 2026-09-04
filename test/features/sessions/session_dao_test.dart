import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/environments/domain/environment_path.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/domain/session_lineage.dart';
import 'package:karmashala/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    dao = SessionDao(db);
  });
  tearDown(() => db.close());

  test('insert then read round-trips a session without a worktree', () {
    final s = session();
    dao.insert(s);
    final loaded = dao.getById('s1')!;
    expect(loaded, s);
    expect(loaded.useWorktree, isFalse);
    expect(loaded.worktree, isNull);
  });

  test('persists a per-session worktree choice and location', () {
    final s = session(
      useWorktree: true,
      worktree: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\app-wt',
      ),
    );
    dao.insert(s);
    final loaded = dao.getById('s1')!;
    expect(loaded.useWorktree, isTrue);
    expect(loaded.worktree!.path, r'C:\src\demo\app-wt');
  });

  test('a session with no recorded working directory reads back null', () {
    // Null is "we never recorded it", not "the repository root". Every row
    // written before schema v22 is this shape, and a reader that wants a
    // directory falls back on its own rather than being handed a claim.
    dao.insert(session());
    expect(dao.getById('s1')!.workingDirectory, isNull);
  });

  test('round-trips the directory the agent runs in, with its environment', () {
    const cwd = EnvironmentPath(
      environmentId: 'wsl:Ubuntu',
      path: '/home/me/src/demo/app/packages/ui',
    );
    dao.insert(session().copyWith(workingDirectory: cwd));
    final loaded = dao.getById('s1')!;
    expect(loaded.workingDirectory, cwd);
    // And it is emphatically not the worktree: that field drives
    // `use_worktree` and `WorktreeService.remove`, which deletes the directory.
    expect(loaded.worktree, isNull);
    expect(loaded.useWorktree, isFalse);
  });

  test('updateWorkingDirectory changes only the working directory', () {
    dao.insert(session(title: 'Adopted'));
    dao.updateWorkingDirectory(
      's1',
      const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\app\tool',
      ),
    );
    final loaded = dao.getById('s1')!;
    expect(loaded.workingDirectory!.path, r'C:\src\demo\app\tool');
    expect(loaded.title, 'Adopted');
    expect(loaded.status, SessionStatus.created);
    expect(loaded.worktree, isNull);
  });

  test('updateStatus changes only the status', () {
    dao.insert(session());
    dao.updateStatus('s1', SessionStatus.running);
    expect(dao.getById('s1')!.status, SessionStatus.running);
  });

  test('a session with no chosen model reads back null, not a default', () {
    // Schema v28. Null is the value every pre-v28 row is truthfully in, and
    // the state "let the agent choose" writes back — a fabricated model id
    // here would be a claim about what a session ran on.
    dao.insert(session());
    expect(dao.getById('s1')!.modelId, isNull);

    dao.updateModel('s1', 'opus');
    expect(dao.getById('s1')!.modelId, 'opus');

    // Cleared and never set must read back identically, or the chip would
    // have two spellings of one state and pass an empty `--model`.
    dao.updateModel('s1', '');
    expect(dao.getById('s1')!.modelId, isNull);
    dao.updateModel('s1', 'sonnet');
    dao.updateModel('s1', null);
    expect(dao.getById('s1')!.modelId, isNull);
  });

  test('persists the CLI session id used for external resume', () {
    dao.insert(session());
    dao.updateExternalSessionId('s1', 'cli-thread-42');
    expect(dao.getById('s1')!.externalSessionId, 'cli-thread-42');
  });

  test('duplicate rows for one CLI conversation read back newest first', () {
    // `external_session_id` carries no UNIQUE constraint (migrations.dart:171)
    // and a resume used to mint a second row for a conversation that already
    // had one, so two rows sharing an id is a shape the database really holds.
    // Written oldest-first, which is the order a query with no ORDER BY answers
    // in — so "the" row was the stale one.
    dao.insert(session(id: 'older').copyWith(externalSessionId: 'ext-1'));
    dao.insert(
      session(id: 'newer').copyWith(
        createdAt: testTime.add(const Duration(minutes: 5)),
        externalSessionId: 'ext-1',
      ),
    );

    expect(dao.getAllByExternalSessionId('ext-1').map((s) => s.id).toList(), [
      'newer',
      'older',
    ]);
    expect(dao.getByExternalSessionId('ext-1')!.id, 'newer');
    expect(dao.getAllByExternalSessionId('nobody'), isEmpty);
    expect(dao.getByExternalSessionId('nobody'), isNull);
  });

  test(
    'duplicates written in the same instant still order deterministically',
    () {
      // The tie-break earns its place: rows minted in one burst share a
      // timestamp to the microsecond, and an ordering that stops at `created_at`
      // would hand those back in whatever order the engine felt like.
      for (final id in ['b', 'a', 'c']) {
        dao.insert(session(id: id).copyWith(externalSessionId: 'ext-1'));
      }
      expect(dao.getAllByExternalSessionId('ext-1').map((s) => s.id).toList(), [
        'c',
        'b',
        'a',
      ]);
    },
  );

  test('getByRepository filters by repository', () {
    dao.insert(session(id: 's1'));
    dao.insert(session(id: 's2', title: 'Other'));
    expect(dao.getByRepository('r1').length, 2);
    expect(dao.getByRepository('rX'), isEmpty);
  });

  group('repositoryIdsById', () {
    test('places every row, and nothing else about it', () {
      dao.insert(session(id: 's1'));
      dao.insert(session(id: 's2'));
      expect(dao.repositoryIdsById(), {'s1': 'r1', 's2': 'r1'});
    });

    test('is empty on an empty table, not absent', () {
      expect(dao.repositoryIdsById(), isEmpty);
    });

    test('agrees with the decoded rows it replaced', () {
      // The property: a narrow read must answer what building the whole
      // session and reading two fields off it answered.
      for (var i = 0; i < 5; i++) {
        dao.insert(session(id: 's$i'));
      }
      expect(dao.repositoryIdsById(), {
        for (final row in dao.getAll()) row.id: row.repositoryId,
      });
    });
  });

  /// **The project header's two integers.**
  ///
  /// A count that is cheap and wrong is worse than the rows it replaced, so
  /// these check the arithmetic rather than the plan: the same answers the
  /// header used to get by building every session and counting them.
  group('countsByRepositories', () {
    test('counts the rows and the running ones', () {
      dao.insert(session(id: 's1', status: SessionStatus.running));
      dao.insert(session(id: 's2', status: SessionStatus.running));
      dao.insert(session(id: 's3', status: SessionStatus.completed));
      expect(dao.countsByRepositories(['r1']), (sessions: 3, running: 2));
    });

    test('and only under the repositories it was given', () {
      dao.insert(session(id: 's1', status: SessionStatus.running));
      expect(dao.countsByRepositories(['rX']), (sessions: 0, running: 0));
    });

    test('no repositories is zero, not every session', () {
      // A project with no checkouts must read as empty. The `IN ()` this would
      // otherwise build is not valid SQL, and the shape that *is* valid — no
      // `WHERE` at all — would count the whole workspace under one header.
      dao.insert(session(id: 's1', status: SessionStatus.running));
      expect(dao.countsByRepositories(const []), (sessions: 0, running: 0));
    });

    test('a status nothing recognises still counts as a session', () {
      // `_statusFrom` reads an unknown word as `SessionStatus.unknown` rather
      // than throwing the row away, and the header counts the same way: the
      // row exists whatever it claims to be doing.
      dao.insert(session(id: 's1'));
      db.execute("UPDATE sessions SET status = 'martian' WHERE id = 's1';");
      expect(dao.countsByRepositories(['r1']), (sessions: 1, running: 0));
    });

    test('agrees with counting the rows one at a time', () {
      // The property the change has to preserve: whatever `getByRepository`
      // would have answered, this answers.
      for (var i = 0; i < 7; i++) {
        dao.insert(
          session(
            id: 's$i',
            status: i.isEven ? SessionStatus.running : SessionStatus.completed,
          ),
        );
      }
      final rows = dao.getByRepository('r1');
      expect(dao.countsByRepositories(['r1']), (
        sessions: rows.length,
        running: rows
            .where((s) => s.status == SessionStatus.running)
            .length,
      ));
    });
  });

  test('deleting the repository cascades to its sessions', () {
    dao.insert(session());
    RepositoryDao(db).delete('r1');
    expect(dao.getById('s1'), isNull);
  });

  test('round-trips why a session has a parent', () {
    dao.insert(session(id: 'parent'));
    for (final link in SessionLink.values) {
      dao.insert(
        session(
          id: 'child-${link.name}',
        ).copyWith(parentSessionId: 'parent', parentLink: link),
      );
      expect(dao.getById('child-${link.name}')!.parentLink, link);
    }
  });

  test('a root session stores no link at all', () {
    dao.insert(session());
    expect(dao.getById('s1')!.parentLink, isNull);
    expect(dao.getById('s1')!.parentSessionId, isNull);
  });

  test('childrenOf returns every kind of child, oldest first', () {
    dao.insert(session(id: 'parent'));
    dao.insert(
      session(
        id: 'a',
      ).copyWith(parentSessionId: 'parent', parentLink: SessionLink.handoff),
    );
    dao.insert(
      session(
        id: 'b',
      ).copyWith(parentSessionId: 'parent', parentLink: SessionLink.fork),
    );
    expect(dao.childrenOf('parent').map((s) => s.parentLink).toList(), [
      SessionLink.handoff,
      SessionLink.fork,
    ]);
  });
}
