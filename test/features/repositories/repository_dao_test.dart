import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_repository_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late RepositoryDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    dao = RepositoryDao(db);
  });
  tearDown(() => db.close());

  test('insert then read round-trips a repository', () {
    final r = repository();
    dao.insert(r);
    expect(dao.getById('r1'), r);
  });

  test('getByProject filters by project', () {
    dao.insert(repository(id: 'r1', name: 'app'));
    dao.insert(repository(id: 'r2', name: 'api', path: r'C:\src\demo\api'));
    final repos = dao.getByProject('p1');
    expect(repos.map((r) => r.name), ['app', 'api']);
    expect(dao.getByProject('other'), isEmpty);
  });

  test('deleting the parent project cascades to its repositories', () {
    dao.insert(repository());
    ProjectDao(db).delete('p1');
    expect(dao.getById('r1'), isNull);
  });

  group('historyReferenceCount', () {
    setUp(() => AgentInstallationDao(db).insert(agentInstallation()));

    test('is zero for a repository nothing points at', () {
      dao.insert(repository());
      expect(dao.historyReferenceCount('r1'), 0);
    });

    test('counts native sessions, secondary links and imported history', () {
      dao.insert(repository(id: 'r1'));
      dao.insert(repository(id: 'r2', name: 'api', path: r'C:\src\demo\api'));
      final sessions = SessionDao(db);
      sessions.insert(session(id: 's1', repositoryId: 'r1'));
      // A session whose *primary* repository is elsewhere but which is linked
      // to r1 as well — deleting r1 would take that link with it.
      sessions.insert(session(id: 's2', repositoryId: 'r2'));
      SessionRepositoryDao(db).link('s2', 'r1');
      ImportedSessionDao(db).insertIfAbsent(
        ImportedSession(
          id: 'i1',
          repositoryId: 'r1',
          cli: 'claude-code',
          externalId: 'ext-1',
          environmentId: 'windows',
          filePath: r'C:\store\ext-1.jsonl',
          storeHome: r'C:\store',
          isSubagent: false,
          preview: 'hello',
          createdAt: testTime,
        ),
      );

      expect(dao.historyReferenceCount('r1'), 3);
      expect(dao.historyReferenceCount('r2'), 1);
    });

    test('counts fanout comparisons, which outlive their worktrees', () {
      dao.insert(repository());
      // Written here rather than through the fanout DAO: what is under test is
      // this query's reach into every table that cascades, not that feature.
      db.execute(
        'INSERT INTO fanout_comparisons '
        '(id, repository_id, prompt, created_at, outcome, archived) '
        "VALUES ('f1', 'r1', 'try three ways', '2026-01-02', 'merged', 0);",
      );
      expect(dao.historyReferenceCount('r1'), 1);
    });

    test('does not double-count a session through its primary link', () {
      dao.insert(repository());
      SessionDao(db).insert(session(id: 's1', repositoryId: 'r1'));
      SessionRepositoryDao(db).link('s1', 'r1', role: 'primary');
      expect(dao.historyReferenceCount('r1'), 1);
    });
  });
}
