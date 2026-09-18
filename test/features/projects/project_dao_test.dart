import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProjectDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    dao = ProjectDao(db);
  });
  tearDown(() => db.close());

  test('insert then read round-trips, preserving the bound environment', () {
    final p = project();
    dao.insert(p);
    final loaded = dao.getById('p1')!;
    expect(loaded, p);
    expect(loaded.root.environmentId, 'windows');
    expect(loaded.root.path, r'C:\src\demo');
  });

  test('update changes name and root', () {
    dao.insert(project());
    dao.update(project(name: 'Renamed', path: r'C:\src\renamed'));
    final loaded = dao.getById('p1')!;
    expect(loaded.name, 'Renamed');
    expect(loaded.root.path, r'C:\src\renamed');
  });

  test('insert rejects a project referencing an unknown environment', () {
    expect(
      () => dao.insert(project(environmentId: 'ghost')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('delete removes the project', () {
    dao.insert(project());
    dao.delete('p1');
    expect(dao.getAll(), isEmpty);
  });

  /// Every way a project keeps an environment's row from being deleted: rooted
  /// there, a repository there, or a session run by an agent installed there.
  /// Each is a RESTRICT on the way down, so each has to be named up front.
  test('namesUsingEnvironment names every project that holds it', () {
    ExecutionEnvironmentDao(db).upsert(sshEnvFixture());
    final repos = RepositoryDao(db);

    dao.insert(project(id: 'rooted', name: 'Rooted', environmentId: 'ssh:h1'));

    dao.insert(project(id: 'mixed', name: 'Mixed'));
    repos.insert(
      repository(id: 'r-ssh', projectId: 'mixed', environmentId: 'ssh:h1'),
    );

    dao.insert(project(id: 'ran', name: 'Ran there'));
    repos.insert(repository(id: 'r-win', projectId: 'ran'));
    AgentInstallationDao(
      db,
    ).insert(agentInstallation(id: 'a-ssh', environmentId: 'ssh:h1'));
    SessionDao(
      db,
    ).insert(session(repositoryId: 'r-win', agentInstallationId: 'a-ssh'));

    dao.insert(project(id: 'other', name: 'Elsewhere'));

    expect(dao.namesUsingEnvironment('ssh:h1'), [
      'Mixed',
      'Ran there',
      'Rooted',
    ]);
    expect(dao.namesUsingEnvironment('ssh:unused'), isEmpty);
  });
}
