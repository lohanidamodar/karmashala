import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';

import '../../../core/data/data_client.dart';

/// The todo list as the server keeps it: read from this app's copy, written
/// through the server. Each write lands in the copy at once, by the same
/// rules the server applies, and the server's answer replaces it.
class TodosRepository {
  TodosRepository(this._client);

  final DataClient _client;

  /// Fires after the list changed, from here or another client.
  Stream<void> get changes => _client.todos.changes;

  /// Every todo in list order: open ones as arranged, then done ones.
  List<Todo> list() {
    _client.ensurePrimed(DataDomain.todos);
    return [..._client.todos.values]..sort(compareTodos);
  }

  Todo? byId(String id) {
    _client.ensurePrimed(DataDomain.todos);
    return _client.todos[id];
  }

  /// Writes [draft] at the bottom of the list (the server decides the
  /// position; the copy guesses the same). With no project, it is filed
  /// under [projectOfSession]'s when the server knows that session.
  Future<Todo> add(Todo draft, {String? projectOfSession}) {
    _client.todos.setLocal(draft.id, draft);
    return _write(
      TodoAdd(
        id: draft.id,
        body: draft.body,
        projectId: draft.projectId,
        projectOfSession: projectOfSession,
      ),
    );
  }

  Future<Todo> setDone(String id, {required bool done, required DateTime at}) {
    final todo = byId(id);
    if (todo != null) {
      _client.todos.setLocal(
        id,
        done ? todo.copyWith(doneAt: at) : todo.copyWith(clearDoneAt: true),
      );
    }
    return _write(TodoSetDone(id: id, done: done));
  }

  Future<Todo> edit(String id, String body) {
    final todo = byId(id);
    final line = todoBodyOf(body);
    if (todo != null && line != null) {
      _client.todos.setLocal(id, todo.copyWith(body: line));
    }
    return _write(TodoEdit(id: id, body: body));
  }

  Future<Todo> file(String id, String? projectId) {
    final todo = byId(id);
    if (todo != null) {
      _client.todos.setLocal(
        id,
        todo.copyWith(projectId: projectId, clearProjectId: projectId == null),
      );
    }
    return _write(TodoFile(id: id, projectId: projectId));
  }

  Future<List<Todo>> move(String id, {required bool up}) {
    final todos = list();
    final order = openOrderAfterMove(todos, id, up: up);
    if (order == null) return Future.value(todos);
    for (var i = 0; i < order.length; i++) {
      final todo = byId(order[i]);
      if (todo != null) {
        _client.todos.setLocal(todo.id, todo.copyWith(position: i));
      }
    }
    return _client.write(
      TodoMove(id: id, up: up),
      domain: DataDomain.todos,
      apply: (all, revision) {
        for (final todo in all) {
          _client.todos.applyAt(todo.id, todo, revision);
        }
      },
    );
  }

  Future<void> delete(String id) {
    _client.todos.setLocal(id, null);
    return _client.write(
      TodoDelete(id),
      domain: DataDomain.todos,
      apply: (_, revision) => _client.todos.applyAt(id, null, revision),
    );
  }

  /// Deletes those of [ids] that are done; the copy drops them at once.
  Future<int> clearDone(List<String> ids) {
    final going = [
      for (final id in ids)
        if (byId(id)?.isDone ?? false) id,
    ];
    for (final id in going) {
      _client.todos.setLocal(id, null);
    }
    return _client.write(
      TodosClearDone(going),
      domain: DataDomain.todos,
      apply: (_, revision) {
        for (final id in going) {
          _client.todos.applyAt(id, null, revision);
        }
      },
    );
  }

  Future<Todo> _write(DataRequest<Todo> request) => _client.write(
    request,
    domain: DataDomain.todos,
    apply: (todo, revision) => _client.todos.applyAt(todo.id, todo, revision),
  );
}
