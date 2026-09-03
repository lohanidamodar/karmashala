import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/workspaces/data/workspace_dao.dart';
import 'package:karmashala/src/features/workspaces/domain/workspace.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late WorkspaceDao dao;
  late ProjectDao projects;

  Workspace workspace({
    String id = 'w1',
    String name = 'PopupBits',
    String? description,
  }) => Workspace(
    id: id,
    name: name,
    description: description,
    createdAt: testTime,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    dao = WorkspaceDao(db);
    projects = ProjectDao(db);
  });
  tearDown(() => db.close());

  test('insert then read round-trips', () {
    dao.insert(workspace());
    expect(dao.getById('w1'), workspace());
  });

  test('getAll orders by name, ignoring case', () {
    dao.insert(workspace(id: 'w1', name: 'personal'));
    dao.insert(workspace(id: 'w2', name: 'Appwrite'));
    dao.insert(workspace(id: 'w3', name: 'game dev'));
    expect(dao.getAll().map((w) => w.name), [
      'Appwrite',
      'game dev',
      'personal',
    ]);
  });

  test('updateDetails changes the name and the description, and nothing else', () {
    dao.insert(workspace(description: 'The shipped apps'));
    dao.updateDetails('w1', name: 'PopupBits Ltd', description: 'Ships');
    final loaded = dao.getById('w1')!;
    expect(loaded.name, 'PopupBits Ltd');
    expect(loaded.description, 'Ships');
    expect(loaded.createdAt, testTime);
  });

  test('a description round-trips, and a null one stays null', () {
    dao.insert(workspace(description: 'Everything I run for myself'));
    dao.insert(workspace(id: 'w2', name: 'Games'));
    expect(dao.getById('w1')!.description, 'Everything I run for myself');
    expect(dao.getById('w2')!.description, isNull);

    // Emptying the field removes the sentence; the context stays.
    dao.updateDetails('w1', name: 'PopupBits');
    expect(dao.getById('w1')!.description, isNull);
    expect(dao.getById('w1')!.name, 'PopupBits');
  });

  test('a duplicate name is refused whatever the case', () {
    dao.insert(workspace());
    expect(
      () => dao.insert(workspace(id: 'w2', name: 'popupbits')),
      throwsA(isA<SqliteException>()),
    );
  });

  test('deleting a workspace leaves its projects, unassigned', () {
    dao.insert(workspace());
    projects.insert(project(id: 'p1'));
    projects.setWorkspace('p1', 'w1');
    expect(projects.getById('p1')!.workspaceId, 'w1');

    dao.delete('w1');

    expect(dao.getAll(), isEmpty);
    final survivor = projects.getById('p1');
    expect(survivor, isNotNull, reason: 'the project outlives its context');
    expect(survivor!.workspaceId, isNull);
    expect(survivor.name, 'Demo', reason: 'nothing else about it moved');
  });

  test('setWorkspace files and unfiles a project', () {
    dao.insert(workspace());
    projects.insert(project(id: 'p1'));
    expect(projects.getById('p1')!.workspaceId, isNull);

    projects.setWorkspace('p1', 'w1');
    expect(projects.getById('p1')!.workspaceId, 'w1');

    projects.setWorkspace('p1', null);
    expect(projects.getById('p1')!.workspaceId, isNull);
  });

  test('a project round-trips its workspace through insert and update', () {
    dao.insert(workspace());
    dao.insert(workspace(id: 'w2', name: 'Personal'));
    projects.insert(project(id: 'p1').copyWith(workspaceId: 'w1'));
    expect(projects.getById('p1')!.workspaceId, 'w1');

    projects.update(projects.getById('p1')!.copyWith(workspaceId: 'w2'));
    expect(projects.getById('p1')!.workspaceId, 'w2');

    // `copyWith` cannot say "unassign" — null there means "leave it" — so the
    // domain has a verb for it and `update` has to honour it.
    projects.update(projects.getById('p1')!.withoutWorkspace());
    expect(projects.getById('p1')!.workspaceId, isNull);
  });
}
