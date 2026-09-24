/// The desktop's notes and todo list, as `notes.get` answers them — read-only
/// on the phone, and each bounded so one long note cannot fill a frame.
library;

import '../util/bounded_text.dart';

/// The most bytes of one note's body sent to a phone — a phone's reading of
/// it, not an archive; the rest is on the desktop.
const int kMaxRemoteNoteBytes = 4 * 1024;

/// The most notes and todos one answer carries. With [kMaxRemoteNoteBytes]
/// they keep the frame well inside `kMaxEnvelopeBytes`; the rest are counted.
const int kMaxRemoteNotes = 100;
const int kMaxRemoteTodos = 300;

class RemoteNote {
  const RemoteNote({
    required this.id,
    required this.title,
    required this.body,
    required this.updatedAt,
    this.projectName,
    this.truncated = false,
  });

  final String id;

  /// The note's title, or its first line when it has none.
  final String title;
  final String body;
  final DateTime updatedAt;

  /// The project it is filed under, or null for a loose note.
  final String? projectName;

  /// Whether [body] was cut to [kMaxRemoteNoteBytes].
  final bool truncated;

  /// Bounds [body] once, here, so every path that sends a note sends the same.
  factory RemoteNote.bounded({
    required String id,
    required String title,
    required String body,
    required DateTime updatedAt,
    String? projectName,
  }) {
    final (text, cut) = boundedText(body, maxBytes: kMaxRemoteNoteBytes);
    return RemoteNote(
      id: id,
      title: title,
      body: text,
      updatedAt: updatedAt,
      projectName: projectName,
      truncated: cut,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (projectName != null) 'project': projectName,
    if (truncated) 'truncated': true,
  };

  static RemoteNote? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String) return null;
    return RemoteNote(
      id: id,
      title: json['title'] is String ? json['title'] as String : '',
      body: json['body'] is String ? json['body'] as String : '',
      updatedAt:
          DateTime.tryParse('${json['updatedAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      projectName: json['project'] is String ? json['project'] as String : null,
      truncated: json['truncated'] == true,
    );
  }
}

class RemoteTodo {
  const RemoteTodo({
    required this.id,
    required this.body,
    this.done = false,
    this.projectName,
  });

  final String id;
  final String body;
  final bool done;
  final String? projectName;

  Map<String, Object?> toJson() => {
    'id': id,
    'body': body,
    if (done) 'done': true,
    if (projectName != null) 'project': projectName,
  };

  static RemoteTodo? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final body = json['body'];
    if (id is! String || body is! String) return null;
    return RemoteTodo(
      id: id,
      body: body,
      done: json['done'] == true,
      projectName: json['project'] is String ? json['project'] as String : null,
    );
  }
}

/// What `notes.get` answers. [notesEnabled] is false when the desktop has
/// notes switched off, so the phone can say so rather than show "no notes".
class RemoteNotesSnapshot {
  const RemoteNotesSnapshot({
    required this.notes,
    required this.todos,
    this.notesEnabled = true,
    this.omittedNotes = 0,
    this.omittedTodos = 0,
  });

  /// Newest first.
  final List<RemoteNote> notes;

  /// In the desktop's own order, open ones before done ones.
  final List<RemoteTodo> todos;
  final bool notesEnabled;

  /// How many older notes, and later todos, were past the per-answer caps.
  final int omittedNotes;
  final int omittedTodos;

  Map<String, Object?> toJson() => {
    'notes': [for (final n in notes) n.toJson()],
    'todos': [for (final t in todos) t.toJson()],
    if (!notesEnabled) 'notesEnabled': false,
    if (omittedNotes > 0) 'omittedNotes': omittedNotes,
    if (omittedTodos > 0) 'omittedTodos': omittedTodos,
  };

  static RemoteNotesSnapshot fromJson(Map<String, Object?> json) {
    final notes = json['notes'];
    final todos = json['todos'];
    return RemoteNotesSnapshot(
      notes: [
        if (notes is List)
          for (final n in notes) ?RemoteNote.tryFromJson(n),
      ],
      todos: [
        if (todos is List)
          for (final t in todos) ?RemoteTodo.tryFromJson(t),
      ],
      notesEnabled: json['notesEnabled'] != false,
      omittedNotes: json['omittedNotes'] is int
          ? json['omittedNotes'] as int
          : 0,
      omittedTodos: json['omittedTodos'] is int
          ? json['omittedTodos'] as int
          : 0,
    );
  }
}
