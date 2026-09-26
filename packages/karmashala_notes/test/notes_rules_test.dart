import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:test/test.dart';

/// The rules a client's copy follows, beside the table's own order.
void main() {
  final t0 = DateTime.utc(2026, 9, 26);
  Todo todo(String id, int position, {DateTime? doneAt}) =>
      Todo(id: id, body: id, position: position, createdAt: t0, doneAt: doneAt);

  test('open todos by position, then done ones latest first', () {
    final todos = [
      todo('late', 0, doneAt: t0.add(const Duration(hours: 2))),
      todo('b', 1),
      todo('early', 5, doneAt: t0),
      todo('a', 0),
    ]..sort(compareTodos);
    expect([for (final t in todos) t.id], ['a', 'b', 'late', 'early']);
  });

  test('a move swaps with the neighbour among open todos only', () {
    final todos = [todo('a', 0), todo('b', 1), todo('x', 2, doneAt: t0)];
    expect(openOrderAfterMove(todos, 'b', up: true), ['b', 'a']);
    expect(openOrderAfterMove(todos, 'a', up: true), isNull);
    expect(openOrderAfterMove(todos, 'x', up: true), isNull);
    expect(nextTodoPosition(todos), 3);
    expect(nextTodoPosition(const []), 0);
  });

  test('bodies and titles are trimmed; blank is none', () {
    expect(todoBodyOf('  milk '), 'milk');
    expect(todoBodyOf('   '), isNull);
    expect(noteTitleOf('  '), isNull);
    expect(noteTitleOf(' T '), 'T');
    expect(recordIdProblem(''), isNotNull);
    expect(recordIdProblem('note-1'), isNull);
  });

  test('notes newest first, ties by id', () {
    Note note(String id, DateTime at) =>
        Note(id: id, body: id, createdAt: at, updatedAt: at);
    final notes = [
      note('a', t0),
      note('b', t0),
      note('c', t0.add(const Duration(seconds: 1))),
    ]..sort(compareNotes);
    expect([for (final n in notes) n.id], ['c', 'b', 'a']);
  });

  test('values survive their wire shape', () {
    final done = todo('t', 1, doneAt: t0);
    expect(Todo.fromJson(done.toJson()), done);
    final note = Note(id: 'n', body: 'b', createdAt: t0, updatedAt: t0);
    expect(Note.fromJson(note.toJson()), note);
  });
}
