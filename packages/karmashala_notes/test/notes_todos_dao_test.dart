import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_notes/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The two DAOs the server writes notes and todos through, and what a note
/// calls itself. Moved here from the app, which no longer reaches these
/// tables (docs/daemon-architecture.md, slice 1).
void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.memory();
    // A project to file under: `project_id` is a real foreign key.
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('e1', 'windowsNative', 'Windows', '2026-01-01T00:00:00.000Z');",
    );
    db.execute(
      'INSERT INTO projects (id, name, root_environment_id, root_path, '
      "created_at) VALUES ('p1', 'Demo', 'e1', 'C:/src', "
      "'2026-01-01T00:00:00.000Z');",
    );
  });
  tearDown(() => db.close());

  group('notes', () {
    late NoteDao dao;
    setUp(() => dao = NoteDao(db));

    Note note({
      String id = 'n1',
      String body = 'Try a compact mode for the tab strip',
      String? title,
      String? sessionId = 's1',
      int? ordinal = 4,
      DateTime? createdAt,
    }) => Note(
      id: id,
      title: title,
      body: body,
      sourceSessionId: sessionId,
      sourceRepositoryId: sessionId == null ? null : 'r1',
      sourceMessageOrdinal: ordinal,
      sourceMessageRole: sessionId == null ? null : 'agent',
      createdAt: createdAt ?? t0,
      updatedAt: createdAt ?? t0,
    );

    test('a saved note keeps the session and message it came from', () {
      dao.insert(note());
      final stored = dao.getById('n1')!;
      expect(stored.body, 'Try a compact mode for the tab strip');
      expect(stored.sourceSessionId, 's1');
      expect(stored.sourceRepositoryId, 'r1');
      expect(stored.sourceMessageOrdinal, 4);
      expect(stored.sourceMessageRole, 'agent');
      expect(stored.createdAt, t0);
    });

    test('lists newest first, and can be narrowed to one session', () {
      dao
        ..insert(note(id: 'old'))
        ..insert(note(id: 'new', createdAt: t0.add(const Duration(hours: 1))))
        ..insert(note(id: 'other', sessionId: 's2', ordinal: null));
      expect(dao.list().map((n) => n.id), ['new', 'other', 'old']);
      expect(dao.list(sessionId: 's1').map((n) => n.id), ['new', 'old']);
    });

    test('an edit rewrites the text, the filing and the stamp, not the '
        'origin', () {
      dao.insert(note());
      final later = t0.add(const Duration(days: 2));
      dao.update(
        'n1',
        body: 'Compact mode, but only for the tab strip',
        title: 'Tab strip density',
        projectId: 'p1',
        updatedAt: later,
      );
      final stored = dao.getById('n1')!;
      expect(stored.body, 'Compact mode, but only for the tab strip');
      expect(stored.title, 'Tab strip density');
      expect(stored.projectId, 'p1');
      expect(stored.updatedAt, later);
      expect(stored.createdAt, t0, reason: 'when it was kept is a fact');
      expect(stored.sourceSessionId, 's1');
      expect(stored.sourceMessageOrdinal, 4);
      dao.update(
        'n1',
        body: stored.body,
        title: stored.title,
        projectId: null,
        updatedAt: later,
      );
      expect(dao.getById('n1')!.projectId, isNull);
    });

    test('a deleted note is gone and the rest are not', () {
      dao
        ..insert(note(id: 'a'))
        ..insert(note(id: 'b'))
        ..delete('a');
      expect(dao.getById('a'), isNull);
      expect(dao.list().map((n) => n.id), ['b']);
    });

    test('an untitled note is named by its first non-empty line, elided', () {
      expect(
        note(body: '\n  Rework the composer\nand its chips').displayTitle,
        'Rework the composer',
      );
      expect(
        note(title: 'Composer', body: 'Rework it').displayTitle,
        'Composer',
      );
      expect(note(body: '   ').displayTitle, 'Untitled note');
      final long = 'x' * 300;
      final title = note(body: long).displayTitle;
      expect(title.length, 80);
      expect(title.endsWith('…'), isTrue);
      expect(note(body: long).body, long, reason: 'elision is for the list');
    });
  });

  group('todos', () {
    late TodoDao dao;
    setUp(() => dao = TodoDao(db));

    Todo todo({
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
      createdAt: t0,
    );

    test('a todo round-trips, filed or not', () {
      dao
        ..insert(todo())
        ..insert(todo(id: 't2', projectId: 'p1', position: 1));
      expect(dao.getById('t1')!.isFiled, isFalse);
      expect(dao.getById('t2')!.projectId, 'p1');
      expect(dao.getById('t2')!.isFiled, isTrue);
      expect(dao.getById('t1')!.createdAt, t0);
      expect(dao.getById('t1')!.isDone, isFalse);
    });

    test('open todos first in their order, done ones latest first', () {
      dao
        ..insert(todo(id: 'second', position: 1))
        ..insert(todo(id: 'first'))
        ..insert(todo(id: 'old-done', position: 2, doneAt: t0))
        ..insert(
          todo(
            id: 'new-done',
            position: 3,
            doneAt: t0.add(const Duration(hours: 1)),
          ),
        );
      expect(dao.list().map((t) => t.id), [
        'first',
        'second',
        'new-done',
        'old-done',
      ]);
    });

    test('a new todo goes to the bottom; reposition writes the order', () {
      expect(dao.nextPosition(), 0);
      dao
        ..insert(todo(id: 'a'))
        ..insert(todo(id: 'b', position: 1))
        ..insert(todo(id: 'c', position: 7));
      expect(dao.nextPosition(), 8);
      dao.reposition(['c', 'a', 'b']);
      expect(dao.list().map((t) => t.id), ['c', 'a', 'b']);
      expect(dao.list().map((t) => t.position), [0, 1, 2]);
    });

    test('finishing, filing and editing each change one thing', () {
      dao.insert(todo(projectId: 'p1', position: 2));
      final finished = t0.add(const Duration(minutes: 5));
      dao.setDone('t1', finished);
      expect(dao.getById('t1')!.doneAt, finished);
      dao.setDone('t1', null);
      expect(dao.getById('t1')!.isDone, isFalse);

      dao.setProject('t1', null);
      expect(dao.getById('t1')!.projectId, isNull);
      expect(dao.getById('t1')!.position, 2);

      dao.updateBody('t1', 'Rework the tab strip, but only at 720');
      final stored = dao.getById('t1')!;
      expect(stored.body, 'Rework the tab strip, but only at 720');
      expect(stored.position, 2);
      expect(stored.createdAt, t0);
    });

    test('deleteDone takes only finished ones, of those named', () {
      dao
        ..insert(todo(id: 'open'))
        ..insert(todo(id: 'done-1', position: 1, doneAt: t0))
        ..insert(todo(id: 'done-2', position: 2, doneAt: t0));
      expect(dao.deleteDone(ids: ['done-2', 'open']), 1);
      expect(dao.deleteDone(ids: []), 0);
      expect(dao.deleteDone(), 1);
      expect(dao.list().map((t) => t.id), ['open']);
      dao.delete('open');
      expect(dao.list(), isEmpty);
    });
  });
}
