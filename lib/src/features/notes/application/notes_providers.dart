import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../settings/application/settings_controller.dart';
import '../data/note_dao.dart';
import '../domain/note.dart';

final noteDaoProvider = Provider<NoteDao>(
  (ref) => NoteDao(ref.watch(databaseProvider)),
);

/// Whether the Notes feature is on. One reading, so the capture affordance and
/// the browse surface cannot disagree about whether the user asked for this.
final notesEnabledProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider.select((s) => s.notesEnabled)),
);

/// Every note, newest first, kept in memory so the panel rebuilds on a write.
///
/// The list is the state rather than a revision counter over the DAO: notes are
/// few and small, and a surface that re-reads the table on every frame of a
/// resize is a surface that reads the table for no reason.
class NotesController extends Notifier<List<Note>> {
  @override
  List<Note> build() => ref.watch(noteDaoProvider).list();

  NoteDao get _dao => ref.read(noteDaoProvider);

  /// Keeps [body] **exactly as given**. Callers pass the message's own words;
  /// nothing here trims a conversation into a gist. See [Note].
  Note capture({
    required String body,
    String? title,
    String? sourceSessionId,
    String? sourceRepositoryId,
    int? sourceMessageOrdinal,
    String? sourceMessageRole,
  }) {
    final now = ref.read(clockProvider).nowUtc();
    final note = Note(
      id: _newId(now),
      title: title,
      body: body,
      sourceSessionId: sourceSessionId,
      sourceRepositoryId: sourceRepositoryId,
      sourceMessageOrdinal: sourceMessageOrdinal,
      sourceMessageRole: sourceMessageRole,
      createdAt: now,
      updatedAt: now,
    );
    _dao.insert(note);
    state = [note, ...state];
    return note;
  }

  /// Applies the user's edit. An empty title clears it, putting the note back
  /// to being named by its first line.
  void edit(String id, {required String body, String? title}) {
    final index = state.indexWhere((n) => n.id == id);
    if (index == -1) return;
    final trimmedTitle = title?.trim();
    final named = trimmedTitle == null || trimmedTitle.isEmpty
        ? null
        : trimmedTitle;
    final now = ref.read(clockProvider).nowUtc();
    _dao.update(id, body: body, title: named, updatedAt: now);
    final updated = state[index].copyWith(
      body: body,
      title: named,
      clearTitle: named == null,
      updatedAt: now,
    );
    state = [...state]..[index] = updated;
  }

  void delete(String id) {
    _dao.delete(id);
    state = [
      for (final note in state)
        if (note.id != id) note,
    ];
  }

  /// Unique within a run and sortable. A counter rides along with the clock
  /// because two taps in the same millisecond is a double-click, not a rarity,
  /// and a fixed clock in a test makes it a certainty.
  String _newId(DateTime now) =>
      'note-${now.microsecondsSinceEpoch}-${_sequence++}';

  int _sequence = 0;
}

final notesProvider = NotifierProvider<NotesController, List<Note>>(
  NotesController.new,
);
