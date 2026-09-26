import 'dart:convert';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_notes/store.dart';

import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// `notes_list`, `note_add`, `note_delete`, `todos_list`, `todo_add`,
/// `todo_done`, `todo_delete`: the scratchpad and the list a person and an
/// agent both write to. Read from the store, written through the data API —
/// so the app's panels see an agent's note the moment it is kept — and filed
/// by the server's own rules (`NotesHandler`, `TodosHandler`).
class NotesTodosToolSet extends ServerToolSet {
  NotesTodosToolSet(this._context)
    : _notes = NoteDao(_context.database),
      _todos = TodoDao(_context.database);

  final ServerToolContext _context;
  final NoteDao _notes;
  final TodoDao _todos;

  /// The argument that means "filed under no project at all" — a real value,
  /// because a string cannot carry "not given" against "explicitly nothing".
  static const String unfiled = 'none';

  /// The preference the app keeps its settings in, and the key in it that
  /// says whether the Notes panel is on (`Settings.notesEnabled`).
  static const String settingsKey = 'settings.v1';

  @override
  List<Map<String, Object?>> get schemas => notesTodosToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() => _run(tool, arguments, callerSessionId));

  Object? _run(String tool, Map<String, dynamic> args, String? caller) =>
      switch (tool) {
        'notes_list' => _notesList(
          args['sessionId'] as String?,
          projectId: args['projectId'] as String?,
        ),
        'note_add' => _noteAdd(
          body: (args['body'] as String?) ?? '',
          title: args['title'] as String?,
          sessionId: args['sessionId'] as String? ?? caller,
          projectId: args['projectId'] as String?,
        ),
        'note_delete' => _noteDelete(args['id'] as String?),
        'todos_list' => _todosList(
          projectId: args['projectId'] as String?,
          includeDone: args['includeDone'] == true,
        ),
        'todo_add' => _todoAdd(
          body: (args['body'] as String?) ?? '',
          projectId: args['projectId'] as String?,
          caller: caller,
        ),
        'todo_done' => _todoDone(
          args['id'] as String?,
          done: args['done'] is bool ? args['done']! as bool : true,
        ),
        'todo_delete' => _todoDelete(args['id'] as String?),
        _ => throw ArgumentError('Unknown tool: $tool'),
      };

  // Notes.

  /// The notes, newest first, optionally narrowed to one session and one
  /// project, where `projectId: 'none'` means the unfiled ones.
  Object? _notesList(String? sessionId, {String? projectId}) {
    final notes = <Note>[
      for (final note in _notes.list()..sort(compareNotes))
        if ((sessionId == null || note.sourceSessionId == sessionId) &&
            (projectId == null ||
                (projectId == unfiled
                    ? note.projectId == null
                    : note.projectId == projectId)))
          note,
    ];
    return <String, Object?>{
      // Whether the panel is switched on. A caller adding notes into a surface
      // nobody can see deserves to know that, and it is not a reason to refuse.
      'notesPanelEnabled': notesPanelEnabled(),
      'notes': <Object?>[
        for (final note in notes)
          <String, Object?>{
            'id': note.id,
            'title': note.displayTitle,
            'body': note.body,
            'projectId': note.projectId,
            'sourceSessionId': note.sourceSessionId,
            'sourceRepositoryId': note.sourceRepositoryId,
            'createdAt': note.createdAt.toIso8601String(),
            'updatedAt': note.updatedAt.toIso8601String(),
          },
      ],
    };
  }

  /// Whether the Notes panel is on, as the app's settings preference says —
  /// on unless it was turned off, which is the app's own default for a
  /// preference that is absent or unreadable.
  bool notesPanelEnabled() {
    final raw = _context.database.readMetadata(settingsKey);
    if (raw == null) return true;
    try {
      final settings = jsonDecode(raw);
      if (settings is Map<String, dynamic> &&
          settings['notesEnabled'] is bool) {
        return settings['notesEnabled'] as bool;
      }
    } on FormatException {
      // The app reads an unreadable preference as its defaults.
    }
    return true;
  }

  /// Keeps [body] **exactly as given**: a note is evidence, and a
  /// paraphrase's errors are invisible to whoever reads it next. An explicit
  /// project wins, `'none'` files it nowhere, and omitting it follows the
  /// session's own repository.
  Object? _noteAdd({
    required String body,
    String? title,
    String? sessionId,
    String? projectId,
  }) {
    if (body.trim().isEmpty) {
      throw ArgumentError('body is required and cannot be blank.');
    }
    final isUnfiled = projectId == unfiled;
    final note = _context.write(
      NoteCapture(
        id: _context.newId(),
        body: body,
        title: noteTitleOf(title),
        projectId: isUnfiled ? null : projectId,
        inheritProject: !isUnfiled,
        sourceSessionId: sessionId,
      ),
    );
    return <String, Object?>{
      'id': note.id,
      'title': note.displayTitle,
      'projectId': note.projectId,
      'sourceSessionId': note.sourceSessionId,
      'createdAt': note.createdAt.toIso8601String(),
    };
  }

  Object? _noteDelete(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. notes_list has the ids.');
    }
    if (_notes.getById(id) == null) {
      throw StateError('No note with id $id.');
    }
    _context.write(NoteDelete(id));
    return <String, Object?>{'id': id, 'deleted': true};
  }

  // Todos.

  /// Open todos first in the user's own order, then the finished ones.
  Object? _todosList({String? projectId, required bool includeDone}) {
    final matching = <Todo>[
      for (final todo in _todos.list()..sort(compareTodos))
        if ((includeDone || !todo.isDone) && _files(todo, projectId)) todo,
    ];
    return <String, Object?>{
      'open': matching.where((todo) => !todo.isDone).length,
      'todos': <Object?>[for (final todo in matching) _describe(todo)],
    };
  }

  static bool _files(Todo todo, String? projectId) {
    if (projectId == null) return true;
    if (projectId == unfiled) return todo.projectId == null;
    return todo.projectId == projectId;
  }

  /// Writes a todo at the bottom of the list, never the top: the top is where
  /// the person using it put the thing that matters most. An explicit id
  /// wins, `'none'` files it nowhere, and omitting it follows the **calling
  /// session's** project.
  Object? _todoAdd({required String body, String? projectId, String? caller}) {
    if (body.trim().isEmpty) {
      throw ArgumentError('body is required and cannot be blank.');
    }
    final given = projectId != null && projectId.isNotEmpty;
    return _describe(
      _context.write(
        TodoAdd(
          id: _context.newId(),
          body: body,
          projectId: given && projectId != unfiled ? projectId : null,
          projectOfSession: given ? null : caller,
        ),
      ),
    );
  }

  /// Ticks a todo off, or reopens it with `done: false`. Not destructive: the
  /// row is still there, and one more call puts it back.
  Object? _todoDone(String? id, {required bool done}) {
    final todo = _todo(id);
    return _describe(_context.write(TodoSetDone(id: todo.id, done: done)));
  }

  Object? _todoDelete(String? id) {
    final todo = _todo(id);
    _context.write(TodoDelete(todo.id));
    return <String, Object?>{'id': todo.id, 'deleted': true};
  }

  Todo _todo(String? id) {
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required. todos_list has the ids.');
    }
    return _todos.getById(id) ?? (throw StateError('No todo with id $id.'));
  }

  static Map<String, Object?> _describe(Todo todo) => <String, Object?>{
    'id': todo.id,
    'body': todo.body,
    'done': todo.isDone,
    'projectId': todo.projectId,
    'position': todo.position,
    'createdAt': todo.createdAt.toIso8601String(),
    'doneAt': todo.doneAt?.toIso8601String(),
  };
}

/// The schemas for [NotesTodosToolSet], as the app served them.
const List<Map<String, Object?>> notesTodosToolSchemas = [
  {
    'name': 'notes_list',
    'description':
        'The notes kept in Karmashala, newest first. Pass sessionId to see '
        'only the ones captured from one session, and projectId to see only '
        'the ones filed under one project — or the literal "none" for the '
        'ones filed under no project.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Only notes captured from this session.',
        },
        'projectId': {
          'type': 'string',
          'description':
              'Only notes filed under this project (list_projects has the '
              'ids), or "none" for only the ones filed under no project. '
              'Omit for all of them.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'notesPanelEnabled': {'type': 'boolean'},
        'notes': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'title': {'type': 'string'},
              'body': {'type': 'string'},
              'projectId': {
                'type': ['string', 'null'],
              },
              'sourceSessionId': {
                'type': ['string', 'null'],
              },
              'sourceRepositoryId': {
                'type': ['string', 'null'],
              },
              'createdAt': {'type': 'string'},
              'updatedAt': {'type': 'string'},
            },
            'required': ['id', 'title', 'body'],
          },
        },
      },
      'required': ['notes', 'notesPanelEnabled'],
    },
  },
  {
    'name': 'note_add',
    'description':
        'Write a note. The body is kept EXACTLY as given — nothing here trims '
        'it to a gist — so pass the words that should survive, not a summary '
        'of them. Attributed to the calling session unless sessionId names '
        'another, and filed under that session\'s project unless projectId '
        'says otherwise.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'body': {'type': 'string', 'description': 'The note, verbatim.'},
        'title': {
          'type': 'string',
          'description':
              'Optional. Without one the note is named by its first line.',
        },
        'sessionId': {
          'type': 'string',
          'description':
              'Which session this came from. Defaults to the calling session.',
        },
        'projectId': {
          'type': 'string',
          'description':
              'Which project to file it under (list_projects has the ids), or '
              '"none" for no project. Defaults to the project of the session '
              'it came from.',
        },
      },
      'required': ['body'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'title': {'type': 'string'},
        'projectId': {
          'type': ['string', 'null'],
        },
        'sourceSessionId': {
          'type': ['string', 'null'],
        },
        'createdAt': {'type': 'string'},
      },
      'required': ['id', 'title'],
    },
  },
  {
    'name': 'note_delete',
    'description':
        'Delete a note. DESTRUCTIVE: notes are not versioned and there is no '
        'undo.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Note id, from notes_list.'},
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
