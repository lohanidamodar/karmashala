import 'note.dart';

/// Newest first — a note list is a stack of things not done yet. The order
/// `NoteDao.list` reads, so a client's copy and the table agree.
int compareNotes(Note a, Note b) {
  final byCreated = b.createdAt.compareTo(a.createdAt);
  return byCreated != 0 ? byCreated : b.id.compareTo(a.id);
}

/// The title an edit stores: trimmed, and blank means "named by its body".
String? noteTitleOf(String? title) {
  final trimmed = title?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The longest id a client may choose for a note or a todo.
const int kMaxRecordIdLength = 128;

/// Why [id] cannot name a new note or todo, or null when it can.
String? recordIdProblem(String id) {
  if (id.trim().isEmpty) return 'an id is required';
  if (id.length > kMaxRecordIdLength) {
    return 'an id is at most $kMaxRecordIdLength characters';
  }
  return null;
}
