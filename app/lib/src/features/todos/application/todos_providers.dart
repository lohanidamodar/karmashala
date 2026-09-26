import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import '../domain/project_scope.dart';

final todoDaoProvider = Provider<TodoDao>(
  (ref) => TodoDao(ref.watch(databaseProvider)),
);

/// Every todo, in list order, kept in memory so the panel rebuilds on a write.
/// The cost of that is [refresh]: another process can write this table too.
class TodosController extends Notifier<List<Todo>> {
  @override
  List<Todo> build() => ref.watch(todoDaoProvider).list();

  TodoDao get _dao => ref.read(todoDaoProvider);

  /// Writes a todo at the bottom of the list. [body] is kept as given beyond a
  /// trim; [projectId] null means filed under nothing, which is ordinary.
  Todo add({required String body, String? projectId}) {
    final now = ref.read(clockProvider).nowUtc();
    final todo = Todo(
      id: _newId(now),
      body: body.trim(),
      projectId: projectId,
      position: _dao.nextPosition(),
      createdAt: now,
    );
    _dao.insert(todo);
    _reload();
    return todo;
  }

  /// Ticks [id] off, or reopens it. Reopening is why nothing is deleted on
  /// completion: a mis-tick has to be one click to undo.
  void setDone(String id, bool done) {
    _dao.setDone(id, done ? ref.read(clockProvider).nowUtc() : null);
    _reload();
  }

  /// Rewrites the line. An empty edit is ignored rather than deleting the row:
  /// clearing the text of a todo is not how anybody asks for it to be gone.
  void edit(String id, String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    _dao.updateBody(id, trimmed);
    _reload();
  }

  /// Files [id] under [projectId], or unfiles it when that is null.
  void setProject(String id, String? projectId) {
    _dao.setProject(id, projectId);
    _reload();
  }

  /// Moves [id] one place up or down among the **open** todos. Menu items rather
  /// than a drag: at 240px a drag is a fiddle, and a keyboard can do this.
  void move(String id, {required bool up}) {
    final open = [
      for (final todo in state)
        if (!todo.isDone) todo,
    ];
    final index = open.indexWhere((todo) => todo.id == id);
    if (index == -1) return;
    final target = up ? index - 1 : index + 1;
    if (target < 0 || target >= open.length) return;
    final ids = [for (final todo in open) todo.id];
    ids[index] = ids[target];
    ids[target] = id;
    _dao.reposition(ids);
    _reload();
  }

  void delete(String id) {
    _dao.delete(id);
    _reload();
  }

  /// Removes what is ticked off in [scope] — the finished rows the panel shows,
  /// so a filtered panel never clears another project's. Returns how many went.
  int clearDone({ProjectScope scope = ProjectScope.all}) {
    final removed = _dao.deleteDone(
      ids: [
        for (final todo in state)
          if (todo.isDone && scope.contains(todo.projectId)) todo.id,
      ],
    );
    _reload();
    return removed;
  }

  /// Re-reads the list rather than patching it in place: every write here can
  /// change the *order*, so the SQL that defines it is what decides it.
  void _reload() => state = _dao.list();

  /// Re-reads the table for a change **this controller did not make** — a write
  /// to the file from outside this process. Asked on panel open and on focus.
  void refresh() {
    final rows = _dao.list();
    if (!listEquals(rows, state)) state = rows;
  }

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
