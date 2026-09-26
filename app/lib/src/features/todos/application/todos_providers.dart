import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_notes/karmashala_notes.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../data/todos_repository.dart';
import '../domain/project_scope.dart';

final todosRepositoryProvider = Provider<TodosRepository>(
  (ref) => TodosRepository(ref.watch(dataClientProvider)),
);

final _log = AppLogger.named('todos');

/// Every todo, in list order, as the server keeps them. Live: a todo an
/// agent or a phone writes arrives here without asking.
class TodosController extends Notifier<List<Todo>> {
  @override
  List<Todo> build() {
    final repository = ref.watch(todosRepositoryProvider);
    final rows = repository.list();
    final changes = repository.changes.listen((_) {
      final next = repository.list();
      if (!listEquals(next, state)) state = next;
    });
    ref.onDispose(changes.cancel);
    return rows;
  }

  TodosRepository get _repository => ref.read(todosRepositoryProvider);

  /// Writes a todo at the bottom of the list. [body] is kept as given beyond a
  /// trim; [projectId] null means filed under nothing, which is ordinary.
  Todo add({required String body, String? projectId}) {
    final (draft, stored) = _add(body: body, projectId: projectId);
    _logged('Adding a todo', stored);
    return draft;
  }

  /// [add], answering the todo as the server stored it. With no
  /// [projectId], filed under [projectOfSession]'s project when the server
  /// knows it. Throws `DataRefused` (a blank body is refused).
  Future<Todo> addStored({
    required String body,
    String? projectId,
    String? projectOfSession,
  }) => _add(
    body: body,
    projectId: projectId,
    projectOfSession: projectOfSession,
  ).$2;

  (Todo, Future<Todo>) _add({
    required String body,
    String? projectId,
    String? projectOfSession,
  }) {
    final now = ref.read(clockProvider).nowUtc();
    final draft = Todo(
      id: _newId(now),
      body: todoBodyOf(body) ?? body,
      projectId: projectId,
      position: nextTodoPosition(_repository.list()),
      createdAt: now,
    );
    return (draft, _repository.add(draft, projectOfSession: projectOfSession));
  }

  /// Ticks [id] off, or reopens it. Reopening is why nothing is deleted on
  /// completion: a mis-tick has to be one click to undo.
  void setDone(String id, bool done) =>
      _logged('Ticking a todo', setDoneStored(id, done));

  /// [setDone], answering the todo as stored. Throws `DataRefused`.
  Future<Todo> setDoneStored(String id, bool done) =>
      _repository.setDone(id, done: done, at: ref.read(clockProvider).nowUtc());

  /// Rewrites the line. An empty edit is ignored rather than deleting the row:
  /// clearing the text of a todo is not how anybody asks for it to be gone.
  void edit(String id, String body) {
    if (todoBodyOf(body) == null) return;
    _logged('Editing a todo', _repository.edit(id, body));
  }

  /// Files [id] under [projectId], or unfiles it when that is null.
  void setProject(String id, String? projectId) =>
      _logged('Filing a todo', _repository.file(id, projectId));

  /// Moves [id] one place up or down among the **open** todos. Menu items rather
  /// than a drag: at 240px a drag is a fiddle, and a keyboard can do this.
  void move(String id, {required bool up}) =>
      _logged('Moving a todo', _repository.move(id, up: up));

  void delete(String id) => _logged('Deleting a todo', deleteStored(id));

  /// [delete], answering how the server took it. Throws `DataRefused`.
  Future<void> deleteStored(String id) => _repository.delete(id);

  /// Removes what is ticked off in [scope] — the finished rows the panel shows,
  /// so a filtered panel never clears another project's. Returns how many went.
  int clearDone({ProjectScope scope = ProjectScope.all}) {
    final ids = [
      for (final todo in state)
        if (todo.isDone && scope.contains(todo.projectId)) todo.id,
    ];
    if (ids.isEmpty) return 0;
    _logged('Clearing done todos', _repository.clearDone(ids));
    return ids.length;
  }

  void _logged(String what, Future<Object?> write) => unawaited(
    write.then<void>(
      (_) {},
      onError: (Object error) => _log.warning('$what failed: $error'),
    ),
  );

  /// Unique within a run and sortable: a counter rides along with the clock,
  /// because two adds in one millisecond is a fast typist or a fixed clock.
  String _newId(DateTime now) =>
      'todo-${now.microsecondsSinceEpoch}-${_sequence++}';

  int _sequence = 0;
}

final todosProvider = NotifierProvider<TodosController, List<Todo>>(
  TodosController.new,
);

/// Which project's todos the panel is showing. Starts at
/// [ProjectScope.all] so a filed and an unfiled todo are equally visible on
/// the day the panel is opened.
class TodoScopeController extends Notifier<ProjectScope> {
  @override
  ProjectScope build() => ProjectScope.all;

  void select(ProjectScope scope) => state = scope;
}

final todoScopeProvider = NotifierProvider<TodoScopeController, ProjectScope>(
  TodoScopeController.new,
);

/// A ticket for "put the cursor in the todo composer", so the palette's **New
/// todo** is a verb. A counter, because two requests are two requests.
class TodoComposerFocus extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state = state + 1;
}

final todoComposerFocusProvider = NotifierProvider<TodoComposerFocus, int>(
  TodoComposerFocus.new,
);
