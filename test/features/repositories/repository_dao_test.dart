import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
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
}
