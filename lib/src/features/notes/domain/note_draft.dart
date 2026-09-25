import 'package:karmashala_notes/karmashala_notes.dart';

/// What a note tab's buffer says about itself, in the order it matters.
enum NoteSaveState {
  /// The buffer is what the store holds.
  saved,

  /// Edits are waiting for the autosave.
  saving,

  /// Nothing is written, so closing the tab drops the note.
  empty,

  /// The note changed elsewhere under unsaved edits; nothing is written until
  /// the user picks which to keep.
  conflict,
}

/// A note tab's buffer: what is being typed, what the store last held, and
/// what the store holds now when that moved under unsaved edits.
class NoteDraft {
  const NoteDraft({
    required this.noteId,
    required this.title,
    required this.body,
    required this.savedTitle,
    required this.savedBody,
    this.theirs,
  });

  factory NoteDraft.of(Note note) {
    final title = storedTitle(note);
    return NoteDraft(
      noteId: note.id,
      title: title,
      body: note.body,
      savedTitle: title,
      savedBody: note.body,
    );
  }

  /// A note's title as the buffer compares it: the store keeps no empty title.
  static String storedTitle(Note note) => note.title?.trim() ?? '';

  final String noteId;
  final String title;
  final String body;
  final String savedTitle;
  final String savedBody;

  /// The store's content when it changed under unsaved edits, else null.
  final ({String title, String body})? theirs;

  bool get isDirty => title.trim() != savedTitle || body != savedBody;
  bool get hasConflict => theirs != null;
  bool get isEmpty => title.trim().isEmpty && body.trim().isEmpty;

  NoteSaveState get saveState {
    if (hasConflict) return NoteSaveState.conflict;
    if (isDirty) return NoteSaveState.saving;
    if (isEmpty) return NoteSaveState.empty;
    return NoteSaveState.saved;
  }

  NoteDraft copyWith({
    String? title,
    String? body,
    String? savedTitle,
    String? savedBody,
    ({String title, String body})? theirs,
    bool clearTheirs = false,
  }) => NoteDraft(
    noteId: noteId,
    title: title ?? this.title,
    body: body ?? this.body,
    savedTitle: savedTitle ?? this.savedTitle,
    savedBody: savedBody ?? this.savedBody,
    theirs: clearTheirs ? null : (theirs ?? this.theirs),
  );
}
