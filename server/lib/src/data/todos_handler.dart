import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_notes/store.dart';
import 'package:karmashala_store/database.dart';

import 'filing_lookup.dart';

/// The todo list at the server: validates, writes the `todos` table and says
/// what changed.
class TodosHandler {
  TodosHandler(AppDatabase db, this._filing, this._now) : _dao = TodoDao(db);

  final TodoDao _dao;
  final FilingLookup _filing;
  final DateTime Function() _now;

  List<Todo> list() => _dao.list();

  Todo add(TodoAdd request, List<DataChange> changes) {
    final problem = recordIdProblem(request.id);
    if (problem != null) throw DataRefused.invalid('todos.add: $problem');
    final body = _body(request.body);
    if (_dao.getById(request.id) != null) {
      throw DataRefused.invalid('a todo with id ${request.id} already exists');
    }
    final fromSession = request.projectOfSession;
    final projectId =
        request.projectId ??
        (fromSession == null ? null : _filing.projectOfSession(fromSession));
    _requireProject(projectId);
    final todo = Todo(
      id: request.id,
      body: body,
      projectId: projectId,
      position: _dao.nextPosition(),
      createdAt: _now(),
    );
    _dao.insert(todo);
    changes.add(TodoChanged(todo));
    return todo;
  }

  Todo setDone(TodoSetDone request, List<DataChange> changes) {
    final todo = _existing(request.id);
    if (todo.isDone == request.done) return todo;
    _dao.setDone(request.id, request.done ? _now() : null);
    return _changed(request.id, changes);
  }

  Todo edit(TodoEdit request, List<DataChange> changes) {
    _existing(request.id);
    _dao.updateBody(request.id, _body(request.body));
    return _changed(request.id, changes);
  }

  Todo file(TodoFile request, List<DataChange> changes) {
    _existing(request.id);
    _requireProject(request.projectId);
    _dao.setProject(request.id, request.projectId);
    return _changed(request.id, changes);
  }

  List<Todo> move(TodoMove request, List<DataChange> changes) {
    _existing(request.id);
    final before = _dao.list();
    final order = openOrderAfterMove(before, request.id, up: request.up);
    if (order == null) return before;
    _dao.reposition(order);
    final after = _dao.list();
    final was = {for (final todo in before) todo.id: todo};
    for (final todo in after) {
      if (was[todo.id] != todo) changes.add(TodoChanged(todo));
    }
    return after;
  }

  DataAck delete(TodoDelete request, List<DataChange> changes) {
    _existing(request.id);
    _dao.delete(request.id);
    changes.add(TodoRemoved(request.id));
    return const DataAck();
  }

  int clearDone(TodosClearDone request, List<DataChange> changes) {
    final done = {
      for (final todo in _dao.list())
        if (todo.isDone) todo.id,
    };
    final going = [
      for (final id in request.ids)
        if (done.contains(id)) id,
    ];
    final removed = _dao.deleteDone(ids: going);
    for (final id in going) {
      changes.add(TodoRemoved(id));
    }
    return removed;
  }

  String _body(String body) =>
      todoBodyOf(body) ?? (throw const DataRefused.invalid('a todo is blank'));

  Todo _existing(String id) =>
      _dao.getById(id) ?? (throw DataRefused.notFound('no todo with id $id'));

  Todo _changed(String id, List<DataChange> changes) {
    final todo = _existing(id);
    changes.add(TodoChanged(todo));
    return todo;
  }

  void _requireProject(String? projectId) {
    if (projectId != null && !_filing.projectExists(projectId)) {
      throw DataRefused.notFound('no project with id $projectId');
    }
  }
}
