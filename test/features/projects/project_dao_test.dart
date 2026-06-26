import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
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
}
