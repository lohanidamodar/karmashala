import 'todo.dart';

/// Open todos first in the user's order, then the done ones most recently
/// finished first — the order `TodoDao.list` reads, for a client's copy.
int compareTodos(Todo a, Todo b) {
  if (a.isDone != b.isDone) return a.isDone ? 1 : -1;
  if (!a.isDone) {
    final byPosition = a.position.compareTo(b.position);
    if (byPosition != 0) return byPosition;
  } else {
    final byDone = b.doneAt!.compareTo(a.doneAt!);
    if (byDone != 0) return byDone;
  }
  return a.id.compareTo(b.id);
}

/// The line a todo stores: trimmed, or null when nothing is left — clearing
/// a todo's text is not how anybody asks for it to be gone.
String? todoBodyOf(String body) {
  final trimmed = body.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Where a new todo goes: the bottom, where you would write it on paper.
int nextTodoPosition(Iterable<Todo> todos) {
  var top = -1;
  for (final todo in todos) {
    if (todo.position > top) top = todo.position;
  }
  return top + 1;
}

/// The open todos' ids after moving [id] one place up or down among them,
/// in the order they are then written as positions `0..n-1`. Null when it is
/// not open or already at that end: nothing moves.
List<String>? openOrderAfterMove(
  Iterable<Todo> todos,
  String id, {
  required bool up,
}) {
  final open = [
    for (final todo in todos)
      if (!todo.isDone) todo,
  ]..sort(compareTodos);
  final index = open.indexWhere((todo) => todo.id == id);
  if (index == -1) return null;
  final target = up ? index - 1 : index + 1;
  if (target < 0 || target >= open.length) return null;
  final ids = [for (final todo in open) todo.id];
  ids[index] = ids[target];
  ids[target] = id;
  return ids;
}
