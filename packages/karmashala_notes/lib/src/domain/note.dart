/// A thought the user chose to keep instead of acting on it. **Quoted, not
/// summarised**: capturing a message stores that message's own words.
class Note {
  const Note({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    this.title,
    this.projectId,
    this.sourceSessionId,
    this.sourceRepositoryId,
    this.sourceMessageOrdinal,
    this.sourceMessageRole,
  });

  final String id;

  /// The user's own name for the note, or null to be named by its first line.
  /// Optional because the fast path — tap, keep typing — never asks for one.
  final String? title;

  /// The note itself: the prompt this will become when it is sent back.
  final String body;

  /// The project this note is filed under, or null. Distinct from
  /// [sourceRepositoryId]: filing is the user's, origin is a fact about the past.
  final String? projectId;

  /// The session the note was taken from, or null when it was written from
  /// nowhere in particular. Not a foreign key in the schema and not a promise
  /// here: the session may since have been deleted.
  final String? sourceSessionId;

  /// The repository that session was working in, kept alongside the session so
  /// a note whose session is gone can still say where it came from.
  final String? sourceRepositoryId;

  /// The captured message's index in the transcript and the role that wrote it —
  /// no message id, which PTY-hosted sessions do not have.
  final int? sourceMessageOrdinal;
  final String? sourceMessageRole;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Whether this note remembers a conversation it came from.
  bool get hasSource => sourceSessionId != null;

  /// Whether this note is filed under a project at all.
  bool get isFiled => projectId != null;

  /// What to call it in a list: the user's title, else the first non-empty line
  /// of the body, trimmed to something a narrow panel can show.
  String get displayTitle {
    final named = title?.trim();
    if (named != null && named.isNotEmpty) return named;
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed.length <= 80 ? trimmed : '${trimmed.substring(0, 79)}…';
      }
    }
    return 'Untitled note';
  }

  Note copyWith({
    String? title,
    bool clearTitle = false,
    String? body,
    String? projectId,
    bool clearProjectId = false,
    DateTime? updatedAt,
  }) => Note(
    id: id,
    title: clearTitle ? null : (title ?? this.title),
    body: body ?? this.body,
    projectId: clearProjectId ? null : (projectId ?? this.projectId),
    sourceSessionId: sourceSessionId,
    sourceRepositoryId: sourceRepositoryId,
    sourceMessageOrdinal: sourceMessageOrdinal,
    sourceMessageRole: sourceMessageRole,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// The wire shape: dates as ISO-8601 UTC, absent fields omitted.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': ?title,
    'body': body,
    'projectId': ?projectId,
    'sourceSessionId': ?sourceSessionId,
    'sourceRepositoryId': ?sourceRepositoryId,
    'sourceMessageOrdinal': ?sourceMessageOrdinal,
    'sourceMessageRole': ?sourceMessageRole,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  /// Throws [FormatException] on a map that is not a note.
  static Note fromJson(Map<String, Object?> json) => Note(
    id: _text(json, 'id'),
    title: json['title'] as String?,
    body: _text(json, 'body'),
    projectId: json['projectId'] as String?,
    sourceSessionId: json['sourceSessionId'] as String?,
    sourceRepositoryId: json['sourceRepositoryId'] as String?,
    sourceMessageOrdinal: json['sourceMessageOrdinal'] as int?,
    sourceMessageRole: json['sourceMessageRole'] as String?,
    createdAt: _date(json, 'createdAt'),
    updatedAt: _date(json, 'updatedAt'),
  );

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.id == id &&
      other.title == title &&
      other.body == body &&
      other.projectId == projectId &&
      other.sourceSessionId == sourceSessionId &&
      other.sourceRepositoryId == sourceRepositoryId &&
      other.sourceMessageOrdinal == sourceMessageOrdinal &&
      other.sourceMessageRole == sourceMessageRole &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    body,
    projectId,
    sourceSessionId,
    sourceRepositoryId,
    sourceMessageOrdinal,
    sourceMessageRole,
    createdAt,
    updatedAt,
  );
}

String _text(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('note: "$key" is not a string');
}

DateTime _date(Map<String, Object?> json, String key) =>
    DateTime.parse(_text(json, key)).toUtc();
