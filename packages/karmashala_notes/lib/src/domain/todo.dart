/// One line of text, done or not, in an order the user chose. No due date,
/// priority, label or assignee — and "filed under nothing" is a place, not a hole.
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

  /// The wire shape: dates as ISO-8601 UTC, absent fields omitted.
  Map<String, Object?> toJson() => {
    'id': id,
    'body': body,
    'projectId': ?projectId,
    'position': position,
    'doneAt': ?doneAt?.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  /// Throws [FormatException] on a map that is not a todo.
  static Todo fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final body = json['body'];
    final position = json['position'];
    final createdAt = json['createdAt'];
    final doneAt = json['doneAt'];
    if (id is! String ||
        body is! String ||
        position is! int ||
        createdAt is! String ||
        (doneAt != null && doneAt is! String)) {
      throw const FormatException('not a todo');
    }
    return Todo(
      id: id,
      body: body,
      projectId: json['projectId'] as String?,
      position: position,
      doneAt: doneAt == null ? null : DateTime.parse(doneAt as String).toUtc(),
      createdAt: DateTime.parse(createdAt).toUtc(),
    );
  }

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
