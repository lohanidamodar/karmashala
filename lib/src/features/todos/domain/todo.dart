/// One line of text, done or not, in an order the user chose.
///
/// ## What it deliberately is not
///
/// There is no due date, no priority, no label and no assignee. The ask was for
/// *simple* todos that an agent and a person can both reach, and every field
/// beyond these is a decision to make before the list is usable. A todo that
/// takes five seconds to write is a todo that gets written.
///
/// ## The three states of [projectId]
///
/// A todo is filed under a project or under nothing, and **nothing is a place,
/// not a hole**. An unfiled todo is an ordinary todo: it is what you get by
/// typing into the panel without choosing anything, it is listed by default,
/// and it is reachable on its own ("No project") rather than only as the
/// remainder of a filter. `Note.projectId` says the same thing about notes.
class Todo {
  const Todo({
    required this.id,
    required this.body,
    required this.position,
    required this.createdAt,
    this.doneAt,
    this.projectId,
  });

  final String id;

  /// The line, exactly as written. Nothing here trims it to a gist.
  final String body;

  /// The project this is filed under, or null for a todo that belongs to no
  /// project. Null is a first-class answer, never a missing one.
  final String? projectId;

  /// Where it sits in the list the user arranged. Dense within the table;
  /// gaps are harmless because only the relative order is ever read.
  final int position;

  /// When it was ticked off, or null while it is still open. The boolean and
  /// the fact in one column — see the v33 migration.
  final DateTime? doneAt;

  final DateTime createdAt;

  bool get isDone => doneAt != null;

  /// Whether this is filed under a project at all.
  bool get isFiled => projectId != null;

  Todo copyWith({
    String? body,
    int? position,
    DateTime? doneAt,
    bool clearDoneAt = false,
    String? projectId,
    bool clearProjectId = false,
  }) => Todo(
    id: id,
    body: body ?? this.body,
    projectId: clearProjectId ? null : (projectId ?? this.projectId),
    position: position ?? this.position,
    doneAt: clearDoneAt ? null : (doneAt ?? this.doneAt),
    createdAt: createdAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Todo &&
      other.id == id &&
      other.body == body &&
      other.projectId == projectId &&
      other.position == position &&
      other.doneAt == doneAt &&
      other.createdAt == createdAt;

  @override
  int get hashCode =>
      Object.hash(id, body, projectId, position, doneAt, createdAt);

  @override
  String toString() => 'Todo($id, ${isDone ? 'done' : 'open'}, $body)';
}
