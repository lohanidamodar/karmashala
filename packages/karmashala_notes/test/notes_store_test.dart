import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_notes/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// The two tables as the session host reads them for a phone, with no app in
/// the process: the same DAOs, the same orders.
void main() {
  final t0 = DateTime.utc(2026, 9, 25, 12);
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('notes are newest first', () {
    final notes = NoteDao(db)
      ..insert(Note(id: 'old', body: 'first', createdAt: t0, updatedAt: t0))
      ..insert(
        Note(
          id: 'new',
          body: 'second',
          createdAt: t0.add(const Duration(minutes: 1)),
          updatedAt: t0,
        ),
      );

    expect([for (final note in notes.list()) note.id], ['new', 'old']);
  });

  test('open todos come first in the order the person set', () {
    final todos = TodoDao(db)
      ..insert(Todo(id: 'b', body: 'two', position: 1, createdAt: t0))
      ..insert(Todo(id: 'a', body: 'one', position: 0, createdAt: t0))
      ..insert(
        Todo(id: 'done', body: 'did', position: 2, createdAt: t0, doneAt: t0),
      );

    expect([for (final todo in todos.list()) todo.id], ['a', 'b', 'done']);
    expect(todos.list().last.isDone, isTrue);
  });
}
