import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../../../core/lifecycle/before_quit.dart';
import '../domain/note.dart';
import '../domain/note_draft.dart';
import 'notes_providers.dart';

/// One note, or null once it is gone. Narrowed to the row, so a write to any
/// other note does not rebuild a tab showing this one.
final noteByIdProvider = Provider.family<Note?, String>(
  (ref, id) => ref.watch(
    notesProvider.select((notes) {
      for (final note in notes) {
        if (note.id == id) return note;
      }
      return null;
    }),
  ),
);

/// The buffers of the notes open in tabs, keyed by note id. Kept out of widget
/// state so a tab that is rebuilt does not lose what was typed into it.
class NoteDrafts extends Notifier<Map<String, NoteDraft>> {
  /// Long enough that a sentence is one write, short enough that switching
  /// away right after typing rarely finds anything unsaved.
  static const autosaveDelay = Duration(milliseconds: 600);

  final Map<String, Timer> _timers = {};

  @override
  Map<String, NoteDraft> build() {
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    });
    ref.listen(notesProvider, (_, notes) => _reconcile(notes));
    ref.onDispose(
      ref.read(beforeQuitHooksProvider).addFlush('note drafts', saveAll),
    );
    return const {};
  }

  /// Writes every buffer an autosave is still waiting on; conflicts stay put.
  void saveAll() {
    for (final noteId in state.keys.toList()) {
      save(noteId);
    }
  }

  Note? _note(String id) {
    for (final note in ref.read(notesProvider)) {
      if (note.id == id) return note;
    }
    return null;
  }

  /// The draft for [noteId], started from the store if there is none yet.
  /// Null when the note does not exist.
  NoteDraft? open(String noteId) {
    final existing = state[noteId];
    if (existing != null) return existing;
    final note = _note(noteId);
    if (note == null) return null;
    final draft = NoteDraft.of(note);
    state = {...state, noteId: draft};
    return draft;
  }

  /// Opens the draft first when there is none, so a view can type before its
  /// post-frame open has run.
  void edit(String noteId, {String? title, String? body}) {
    final draft = state[noteId] ?? open(noteId);
    if (draft == null) return;
    final next = draft.copyWith(title: title, body: body);
    if (next.title == draft.title && next.body == draft.body) return;
    state = {...state, noteId: next};
    _timers.remove(noteId)?.cancel();
    if (next.hasConflict || !next.isDirty) return;
    _timers[noteId] = Timer(autosaveDelay, () => save(noteId));
  }

  /// Writes the buffer now. Does nothing while the note is in conflict: that
  /// write would be exactly the overwrite the conflict exists to prevent.
  void save(String noteId) {
    _timers.remove(noteId)?.cancel();
    final draft = state[noteId];
    final note = _note(noteId);
    if (draft == null || note == null || draft.hasConflict || !draft.isDirty) {
      return;
    }
    // Recorded before the write, so the store's own notification of it reads
    // as this buffer's content rather than as a change from elsewhere.
    state = {
      ...state,
      noteId: draft.copyWith(
        savedTitle: draft.title.trim(),
        savedBody: draft.body,
      ),
    };
    ref
        .read(notesProvider.notifier)
        .edit(
          noteId,
          body: draft.body,
          title: draft.title,
          projectId: note.projectId,
        );
  }

  /// Resolves a conflict in favour of the buffer, and writes it.
  void keepMine(String noteId) {
    final draft = state[noteId];
    final theirs = draft?.theirs;
    if (draft == null || theirs == null) return;
    state = {
      ...state,
      noteId: draft.copyWith(
        savedTitle: theirs.title,
        savedBody: theirs.body,
        clearTheirs: true,
      ),
    };
    save(noteId);
  }

  /// Resolves a conflict in favour of the store, dropping the buffer's edits.
  void takeTheirs(String noteId) {
    final draft = state[noteId];
    final note = _note(noteId);
    if (draft == null || note == null) return;
    _timers.remove(noteId)?.cancel();
    state = {...state, noteId: NoteDraft.of(note)};
  }

  /// Drops the buffer, writing it first when that is safe.
  void release(String noteId) {
    if (!state.containsKey(noteId)) return;
    save(noteId);
    state = {...state}..remove(noteId);
  }

  void _reconcile(List<Note> notes) {
    if (state.isEmpty) return;
    final byId = {for (final note in notes) note.id: note};
    var next = state;
    for (final draft in state.values) {
      final note = byId[draft.noteId];
      if (note == null) continue;
      final title = NoteDraft.storedTitle(note);
      final body = note.body;
      final updated = _against(draft, title, body);
      if (!identical(updated, draft)) {
        next = {...next, draft.noteId: updated};
        if (updated.hasConflict) _timers.remove(draft.noteId)?.cancel();
      }
    }
    if (!identical(next, state)) state = next;
  }

  NoteDraft _against(NoteDraft draft, String title, String body) {
    final theirs = draft.theirs;
    final unchanged = theirs == null
        ? title == draft.savedTitle && body == draft.savedBody
        : title == theirs.title && body == theirs.body;
    if (unchanged) return draft;
    if (title == draft.title.trim() && body == draft.body) {
      return draft.copyWith(
        savedTitle: title,
        savedBody: body,
        clearTheirs: true,
      );
    }
    if (!draft.isDirty) {
      return draft.copyWith(
        title: title,
        body: body,
        savedTitle: title,
        savedBody: body,
        clearTheirs: true,
      );
    }
    return draft.copyWith(theirs: (title: title, body: body));
  }
}

final noteDraftsProvider = NotifierProvider<NoteDrafts, Map<String, NoteDraft>>(
  NoteDrafts.new,
);

/// One note's buffer, or null while no tab has opened it.
final noteDraftProvider = Provider.family<NoteDraft?, String>(
  (ref, id) => ref.watch(noteDraftsProvider.select((drafts) => drafts[id])),
);

/// Notes whose tab cannot close without a question: only a conflict, since
/// anything else is written on the way out.
final conflictedNoteIdsProvider = Provider<Set<String>>(
  (ref) => {
    for (final draft in ref.watch(noteDraftsProvider).values)
      if (draft.hasConflict) draft.noteId,
  },
);
