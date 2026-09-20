import 'package:riverpod/riverpod.dart';

import '../repositories/application/repository_providers.dart';
import '../sessions/application/session_providers.dart';
import '../todos/application/todos_providers.dart';
import '../todos/domain/todo.dart';

/// The list a person and an agent both write to, where `projectId: 'none'` is a
/// real value — a string cannot carry "not given" against "explicitly nothing".
class TodoControlTools {
  TodoControlTools(this._container, {this.callerSessionId});

  final ProviderContainer _container;
  final String? callerSessionId;

  /// The argument that means "filed under no project at all".
  static const String unfiled = 'none';

  static const Set<String> _names = <String>{
    'todos_list',
    'todo_add',
    'todo_done',
    'todo_delete',
  };

  static bool handles(String name) => _names.contains(name);

  Future<Object?> call(String name, Map<String, dynamic> args) async =>
      switch (name) {
        'todos_list' => _list(
          projectId: args['projectId'] as String?,
          includeDone: args['includeDone'] == true,
        ),
        'todo_add' => _add(
          body: (args['body'] as String?) ?? '',
          projectId: args['projectId'] as String?,
        ),
        'todo_done' => _done(
          args['id'] as String?,
          done: args['done'] is bool ? args['done']! as bool : true,
        ),
        'todo_delete' => _delete(args['id'] as String?),
        _ => throw ArgumentError('Unknown tool: $name'),
      };

  /// Open todos first in the user's own order, then the finished ones.
  Object? _list({String? projectId, required bool includeDone}) {
    final todos = _container.read(todoDaoProvider).list();
    final matching = <Todo>[
      for (final todo in todos)
        if ((includeDone || !todo.isDone) && _matches(todo, projectId)) todo,
    ];
    return <String, Object?>{
      'open': matching.where((todo) => !todo.isDone).length,
      'todos': <Object?>[for (final todo in matching) _describe(todo)],
    };
  }

  bool _matches(Todo todo, String? projectId) {
    if (projectId == null) return true;
    if (projectId == unfiled) return todo.projectId == null;
    return todo.projectId == projectId;
  }

  /// Writes a todo at the bottom of the list, never the top: the top is where
  /// the person using it put the thing that matters most.
  Object? _add({required String body, String? projectId}) {
    if (body.trim().isEmpty) {
      throw ArgumentError('body is required and cannot be blank.');
    }
    final todo = _container
        .read(todosProvider.notifier)
        .add(body: body, projectId: _fileUnder(projectId));
    return _describe(todo);
  }

  /// Which project a new todo lands in: an explicit id wins, `'none'` files it
  /// nowhere, and omitting it follows the **calling session's** project.
  String? _fileUnder(String? projectId) {
    if (projectId == unfiled) return null;
    if (projectId != null && projectId.isNotEmpty) return projectId;
    final sessionId = callerSessionId;
    if (sessionId == null) return null;
    final session = _container.read(sessionDaoProvider).getById(sessionId);
    if (session == null) return null;
    return _container
        .read(repositoryDaoProvider)
        .getById(session.repositoryId)
        ?.projectId;
  }

  /// Ticks a todo off, or reopens it with `done: false`. Not destructive: the
  /// row is still there, and one more call puts it back.
  Object? _done(String? id, {required bool done}) {
    final todo = _todo(id);
    _container.read(todosProvider.notifier).setDone(todo.id, done);
    return _describe(_container.read(todoDaoProvider).getById(todo.id)!);
  }

  Object? _delete(String? id) {
    final todo = _todo(id);
    _container.read(todosProvider.notifier).delete(todo.id);
    return <String, Object?>{'id': todo.id, 'deleted': true};
  }

  Todo _todo(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. todos_list has the ids.');
    }
    final todo = _container.read(todoDaoProvider).getById(id);
    if (todo == null) throw StateError('No todo with id $id.');
    return todo;
  }

  Map<String, Object?> _describe(Todo todo) => <String, Object?>{
    'id': todo.id,
    'body': todo.body,
    'done': todo.isDone,
    'projectId': todo.projectId,
    'position': todo.position,
    'createdAt': todo.createdAt.toIso8601String(),
    'doneAt': todo.doneAt?.toIso8601String(),
  };
}

/// The schemas for [TodoControlTools].
const List<Map<String, dynamic>> todoControlToolSchemas = [
  {
    'name': 'todos_list',
    'description':
        'The todo list Karmashala shows the person using it: open todos first '
        'in their own order, then the finished ones. This is a written list, '
        'not an alert queue — nothing appears in it on its own, which is what '
        'makes it different from inbox_list. Pass projectId to see one '
        'project\'s todos, or the literal "none" to see only the ones filed '
        'under no project.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'projectId': {
          'type': 'string',
          'description':
              'Only todos filed under this project (list_projects has the '
              'ids), or "none" for only the ones filed under no project. '
              'Omit for all of them.',
        },
        'includeDone': {
          'type': 'boolean',
          'description': 'Include todos already ticked off. Default false.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'open': {'type': 'number'},
        'todos': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'body': {'type': 'string'},
              'done': {'type': 'boolean'},
              'projectId': {
                'type': ['string', 'null'],
              },
              'position': {'type': 'number'},
              'createdAt': {'type': 'string'},
              'doneAt': {
                'type': ['string', 'null'],
              },
            },
            'required': ['id', 'body', 'done'],
          },
        },
      },
      'required': ['open', 'todos'],
    },
  },
  {
    'name': 'todo_add',
    'description':
        'Add one todo to the bottom of the list. The body is one line, kept '
        'as given. Filed under the calling session\'s project unless '
        'projectId says otherwise; pass the literal "none" for a todo that '
        'belongs to no project, which is an ordinary todo rather than an '
        'unfinished one. Use this for work that outlives your turn — a person '
        'reads this list.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'body': {'type': 'string', 'description': 'The todo, one line.'},
        'projectId': {
          'type': 'string',
          'description':
              'Which project to file it under (list_projects has the ids), or '
              '"none" for no project. Defaults to the calling session\'s '
              'project.',
        },
      },
      'required': ['body'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'body': {'type': 'string'},
        'done': {'type': 'boolean'},
        'projectId': {
          'type': ['string', 'null'],
        },
        'position': {'type': 'number'},
        'createdAt': {'type': 'string'},
        'doneAt': {
          'type': ['string', 'null'],
        },
      },
      'required': ['id', 'body', 'done'],
    },
  },
  {
    'name': 'todo_done',
    'description':
        'Tick a todo off, or reopen it with done: false. Nothing is removed — '
        'the row stays in the list under DONE, so a mistake is one more call '
        'to undo. Tick off only what you actually finished: this list is read '
        'by a person who will not check.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Todo id, from todos_list.'},
        'done': {
          'type': 'boolean',
          'description': 'True to finish it, false to reopen. Default true.',
        },
      },
      'required': ['id'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'body': {'type': 'string'},
        'done': {'type': 'boolean'},
        'projectId': {
          'type': ['string', 'null'],
        },
        'position': {'type': 'number'},
        'createdAt': {'type': 'string'},
        'doneAt': {
          'type': ['string', 'null'],
        },
      },
      'required': ['id', 'body', 'done'],
    },
  },
  {
    'name': 'todo_delete',
    'description':
        'Delete a todo. DESTRUCTIVE: todos are not versioned and there is no '
        'undo. To mark one finished, use todo_done — that keeps the row.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Todo id, from todos_list.'},
      },
      'required': ['id'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'deleted': {'type': 'boolean'},
      },
      'required': ['id', 'deleted'],
    },
  },
];
