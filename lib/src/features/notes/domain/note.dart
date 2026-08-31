/// A thought the user chose to keep instead of acting on it.
///
/// ## The one rule
///
/// **A note is quoted, not summarised.** Capturing a message stores that
/// message's own words; nothing in this feature paraphrases a conversation on
/// the user's behalf. The argument is `HandoffPacket`'s, for the same reason —
/// a verbatim excerpt is either right or visibly incomplete, while a
/// paraphrase's errors are invisible to the reader who most needs them, and the
/// reader here is the agent the note is eventually sent back to.
///
/// Editing is the user's. [updatedAt] says when they took it.
class Note {
  const Note({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    this.title,
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

  /// The session the note was taken from, or null when it was written from
  /// nowhere in particular. Not a foreign key in the schema and not a promise
  /// here: the session may since have been deleted.
  final String? sourceSessionId;

  /// The repository that session was working in, kept alongside the session so
  /// a note whose session is gone can still say where it came from.
  final String? sourceRepositoryId;

  /// The captured message's index in the transcript that was on screen, and the
  /// role that wrote it (`user`, `agent`). Together they answer "what were we
  /// discussing?" without needing a message id that PTY-hosted sessions do not
  /// have.
  final int? sourceMessageOrdinal;
  final String? sourceMessageRole;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Whether this note remembers a conversation it came from.
  bool get hasSource => sourceSessionId != null;

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
    DateTime? updatedAt,
  }) => Note(
    id: id,
    title: clearTitle ? null : (title ?? this.title),
    body: body ?? this.body,
    sourceSessionId: sourceSessionId,
    sourceRepositoryId: sourceRepositoryId,
    sourceMessageOrdinal: sourceMessageOrdinal,
    sourceMessageRole: sourceMessageRole,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.id == id &&
      other.title == title &&
      other.body == body &&
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
    sourceSessionId,
    sourceRepositoryId,
    sourceMessageOrdinal,
    sourceMessageRole,
    createdAt,
    updatedAt,
  );
}
