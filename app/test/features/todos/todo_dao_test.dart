import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_notes/karmashala_notes.dart';

import '../../support/fixtures.dart';
import 'package:karmashala_notes/store.dart';

void main() {
  late AppDatabase db;
  late TodoDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    dao = TodoDao(db);
  });

  tearDown(() => db.close());

  Todo todoFixture({
    String id = 't1',
    String body = 'Rework the tab strip',
    String? projectId,
    int position = 0,
    DateTime? doneAt,
  }) => Todo(
    id: id,
    body: body,
    projectId: projectId,
    position: position,
    doneAt: doneAt,
    createdAt: testTime,
  );

  test('a todo round-trips, filed or not', () {
    dao.insert(todoFixture());
    dao.insert(todoFixture(id: 't2', projectId: 'p1', position: 1));

    expect(dao.getById('t1')!.projectId, isNull);
    expect(dao.getById('t1')!.isFiled, isFalse);
    expect(dao.getById('t2')!.projectId, 'p1');
    expect(dao.getById('t2')!.isFiled, isTrue);
    expect(dao.getById('t1')!.createdAt, testTime);
    expect(dao.getById('t1')!.isDone, isFalse);
  });

  test('open todos come first in their own order, done ones after', () {
    final finished = testTime.add(const Duration(hours: 1));
    dao.insert(todoFixture(id: 'second', position: 1));
    dao.insert(todoFixture(id: 'first', position: 0));
    dao.insert(todoFixture(id: 'old-done', position: 2, doneAt: testTime));
    dao.insert(todoFixture(id: 'new-done', position: 3, doneAt: finished));

    expect(dao.list().map((t) => t.id), [
      'first',
      'second',
      'new-done',
      'old-done',
    ]);
  });

  test('a new todo goes to the bottom, not the top', () {
    expect(dao.nextPosition(), 0, reason: 'an empty list starts at zero');
    dao.insert(todoFixture(position: 0));
    dao.insert(todoFixture(id: 't2', position: 7));
    expect(dao.nextPosition(), 8);
  });

  test('reposition writes the order it was given', () {
    dao.insert(todoFixture(id: 'a', position: 0));
    dao.insert(todoFixture(id: 'b', position: 1));
    dao.insert(todoFixture(id: 'c', position: 2));

    dao.reposition(['c', 'a', 'b']);

    expect(dao.list().map((t) => t.id), ['c', 'a', 'b']);
    expect(dao.list().map((t) => t.position), [0, 1, 2]);
  });

  test('finishing and reopening is one nullable column', () {
    dao.insert(todoFixture());
    final finished = testTime.add(const Duration(minutes: 5));

    dao.setDone('t1', finished);
    expect(dao.getById('t1')!.isDone, isTrue);
    expect(dao.getById('t1')!.doneAt, finished);

    dao.setDone('t1', null);
    expect(dao.getById('t1')!.isDone, isFalse);
    expect(dao.getById('t1')!.doneAt, isNull);
  });

  test('filing and unfiling leaves the text and the order alone', () {
    dao.insert(todoFixture(position: 3));

    dao.setProject('t1', 'p1');
    expect(dao.getById('t1')!.projectId, 'p1');
    expect(dao.getById('t1')!.body, 'Rework the tab strip');
    expect(dao.getById('t1')!.position, 3);

    dao.setProject('t1', null);
    expect(dao.getById('t1')!.projectId, isNull);
  });

  test('an edit rewrites the line and nothing else', () {
    dao.insert(todoFixture(projectId: 'p1', position: 2));

    dao.updateBody('t1', 'Rework the tab strip, but only at 720');

    final stored = dao.getById('t1')!;
    expect(stored.body, 'Rework the tab strip, but only at 720');
    expect(stored.projectId, 'p1');
    expect(stored.position, 2);
    expect(stored.createdAt, testTime);
  });

  test('deleteDone removes the finished ones and reports how many', () {
    dao.insert(todoFixture(id: 'open'));
    dao.insert(todoFixture(id: 'done-1', position: 1, doneAt: testTime));
    dao.insert(todoFixture(id: 'done-2', position: 2, doneAt: testTime));

    expect(dao.deleteDone(), 2);
    expect(dao.list().map((t) => t.id), ['open']);
    expect(dao.deleteDone(), 0);
  });

  test('deleteDone with ids removes only those finished ones', () {
    dao.insert(todoFixture(id: 'open'));
    dao.insert(todoFixture(id: 'done-1', position: 1, doneAt: testTime));
    dao.insert(todoFixture(id: 'done-2', position: 2, doneAt: testTime));

    expect(dao.deleteDone(ids: ['done-2', 'open']), 1);
    expect(dao.list().map((t) => t.id), unorderedEquals(['open', 'done-1']));
    expect(dao.deleteDone(ids: []), 0);
  });

  test('a deleted todo is gone and the rest are not', () {
    dao.insert(todoFixture());
    dao.insert(todoFixture(id: 't2', position: 1));

    dao.delete('t1');

    expect(dao.getById('t1'), isNull);
    expect(dao.list().map((t) => t.id), ['t2']);
  });
}
