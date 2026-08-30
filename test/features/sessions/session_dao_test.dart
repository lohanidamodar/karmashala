import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_lineage.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
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

  test('updateStatus changes only the status', () {
    dao.insert(session());
    dao.updateStatus('s1', SessionStatus.running);
    expect(dao.getById('s1')!.status, SessionStatus.running);
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
