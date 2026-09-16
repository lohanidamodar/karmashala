import 'dart:async';

import 'package:karmashala_terminal_core/geometry.dart';
import 'package:riverpod/riverpod.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import '../domain/note.dart';
import 'note_drafts.dart';
import 'notes_providers.dart';

/// The notes open in [tabs], by pane.
Set<String> noteIdsIn(Iterable<TerminalTab> tabs) => {
  for (final tab in tabs)
    for (final paneId in tab.layout.panes) ?notePaneNoteId(paneId),
};

/// Keeps note tabs honest about the notes behind them. Must be *watched*:
/// Riverpod pauses an unwatched provider's subscriptions.
///
/// - a tab whose note is gone (deleted here, by an agent, or before a restore)
///   closes;
/// - a closed tab's buffer is written, then dropped, and a note left with no
///   text at all is deleted rather than kept as "Untitled note";
/// - a renamed note renames its tab.
class NoteTabsObserver extends Notifier<void> {
  Set<String> _open = const {};

  @override
  void build() {
    ref.listen(
      terminalTabsProvider,
      (_, tabs) => _onTabs(noteIdsIn(tabs)),
      fireImmediately: true,
    );
    ref.listen(notesProvider, _onNotes);
  }

  void _onTabs(Set<String> open) {
    final closed = _open.difference(open);
    _open = open;
    if (closed.isEmpty && open.isEmpty) return;
    // Out of the notification: these write back into the providers that are
    // notifying.
    scheduleMicrotask(() {
      final drafts = ref.read(noteDraftsProvider.notifier);
      final notes = ref.read(notesProvider.notifier);
      for (final id in closed) {
        drafts.release(id);
        final note = _find(ref.read(notesProvider), id);
        if (note != null && _isBlank(note)) notes.delete(id);
      }
      _closeMissing(ref.read(notesProvider));
    });
  }

  void _onNotes(List<Note>? previous, List<Note> notes) {
    if (_open.isEmpty) return;
    scheduleMicrotask(() {
      _closeMissing(ref.read(notesProvider));
      final before = {
        for (final note in previous ?? const <Note>[])
          if (_open.contains(note.id)) note.id: note.displayTitle,
      };
      final renamed = notes.any(
        (note) =>
            _open.contains(note.id) &&
            before.containsKey(note.id) &&
            before[note.id] != note.displayTitle,
      );
      if (renamed) {
        ref
            .read(terminalSessionsControllerProvider.notifier)
            .notifyTitleChanged();
      }
    });
  }

  void _closeMissing(List<Note> notes) {
    final existing = {for (final note in notes) note.id};
    final terminals = ref.read(terminalSessionsControllerProvider.notifier);
    for (final id in _open.difference(existing)) {
      terminals.closePane(notePaneId(id), detach: false);
    }
  }

  static Note? _find(List<Note> notes, String id) {
    for (final note in notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  static bool _isBlank(Note note) =>
      (note.title?.trim().isEmpty ?? true) && note.body.trim().isEmpty;
}

final noteTabsObserverProvider = NotifierProvider<NoteTabsObserver, void>(
  NoteTabsObserver.new,
);
