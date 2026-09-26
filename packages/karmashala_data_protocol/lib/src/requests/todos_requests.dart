part of '../data_request.dart';

/// Every todo in list order (`compareTodos`).
final class TodosList extends DataRequest<List<Todo>> {
  const TodosList();

  static const String name = 'todos.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(List<Todo> result) => _todosToJson(result);

  @override
  List<Todo> resultFromJson(Object? json) => _todosFromJson(kind, json);
}

/// Writes a todo under the client's [id] at the bottom of the list. Filed
/// under [projectId]; with none, under the project of [projectOfSession]
/// when that is given and the server knows it, else under nothing.
final class TodoAdd extends DataRequest<Todo> {
  const TodoAdd({
    required this.id,
    required this.body,
    this.projectId,
    this.projectOfSession,
  });

  factory TodoAdd._from(_Arguments args) => TodoAdd(
    id: args.string('id'),
    body: args.string('body'),
    projectId: args.optionalString('projectId'),
    projectOfSession: args.optionalString('projectOfSession'),
  );

  static const String name = 'todos.add';

  final String id;
  final String body;
  final String? projectId;
  final String? projectOfSession;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {
    'id': id,
    'body': body,
    'projectId': ?projectId,
    'projectOfSession': ?projectOfSession,
  };

  @override
  Object? resultToJson(Todo result) => result.toJson();

  @override
  Todo resultFromJson(Object? json) => _todoFromJson(kind, json);
}

/// Ticks a todo off at the server's clock, or reopens it.
final class TodoSetDone extends DataRequest<Todo> {
  const TodoSetDone({required this.id, required this.done});

  static const String name = 'todos.setDone';

  final String id;
  final bool done;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'done': done};

  @override
  Object? resultToJson(Todo result) => result.toJson();

  @override
  Todo resultFromJson(Object? json) => _todoFromJson(kind, json);
}

/// Rewrites a todo's line; a blank one is refused.
final class TodoEdit extends DataRequest<Todo> {
  const TodoEdit({required this.id, required this.body});

  static const String name = 'todos.edit';

  final String id;
  final String body;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'body': body};

  @override
  Object? resultToJson(Todo result) => result.toJson();

  @override
  Todo resultFromJson(Object? json) => _todoFromJson(kind, json);
}

/// Files a todo under [projectId], or unfiles it.
final class TodoFile extends DataRequest<Todo> {
  const TodoFile({required this.id, this.projectId});

  static const String name = 'todos.file';

  final String id;
  final String? projectId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'projectId': ?projectId};

  @override
  Object? resultToJson(Todo result) => result.toJson();

  @override
  Todo resultFromJson(Object? json) => _todoFromJson(kind, json);
}

/// Moves an open todo one place up or down among the open ones
/// (`openOrderAfterMove`), answering every todo in list order.
final class TodoMove extends DataRequest<List<Todo>> {
  const TodoMove({required this.id, required this.up});

  static const String name = 'todos.move';

  final String id;
  final bool up;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'up': up};

  @override
  Object? resultToJson(List<Todo> result) => _todosToJson(result);

  @override
  List<Todo> resultFromJson(Object? json) => _todosFromJson(kind, json);
}

/// Deletes a todo. Refused [DataRefusalCode.notFound] when there is none.
final class TodoDelete extends DataRequest<DataAck> {
  const TodoDelete(this.id);

  static const String name = 'todos.delete';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Deletes those of [ids] that are done, answering how many went.
final class TodosClearDone extends DataRequest<int> {
  const TodosClearDone(this.ids);

  static const String name = 'todos.clearDone';

  final List<String> ids;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'ids': ids};

  @override
  Object? resultToJson(int result) => result;

  @override
  int resultFromJson(Object? json) => json is int ? json : _badAnswer(kind);
}

List<Object?> _todosToJson(List<Todo> todos) => [
  for (final todo in todos) todo.toJson(),
];

List<Todo> _todosFromJson(String kind, Object? json) => _decode(kind, () {
  return [for (final item in _objects(json, kind)) Todo.fromJson(item)];
});

Todo _todoFromJson(String kind, Object? json) =>
    _decode(kind, () => Todo.fromJson(_object(json, kind)));
