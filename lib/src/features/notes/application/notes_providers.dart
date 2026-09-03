import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../repositories/application/repository_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../todos/domain/project_scope.dart';
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
  ///
  /// An unspecified [projectId] follows the source repository's project, which
  /// is the whole reason capturing from a transcript files anything at all.
  /// [inheritProjectFromSource] is how a caller says *file this under nothing*
  /// — the one thing a nullable `String` cannot say for itself, since null
  /// there already means "you decide".
  Note capture({
    required String body,
    String? title,
    String? projectId,
    bool inheritProjectFromSource = true,
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
      projectId:
          projectId ??
          (inheritProjectFromSource ? _projectOf(sourceRepositoryId) : null),
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

  /// The project a note captured from [repositoryId] belongs to.
  ///
  /// Filing follows the repository because a repository belongs to exactly one
  /// project, so this is a lookup rather than a guess — the same rule the v32
  /// backfill applied to every note taken before the column existed.
  String? _projectOf(String? repositoryId) => repositoryId == null
      ? null
      : ref.read(repositoryDaoProvider).getById(repositoryId)?.projectId;

  /// Applies the user's edit. An empty title clears it, putting the note back
  /// to being named by its first line. [projectId] is the filing the dialog
  /// came back with — null means "no project", which is a choice, so this is
  /// the one field an edit can clear by leaving it out.
  void edit(
    String id, {
    required String body,
    String? title,
    String? projectId,
  }) {
    final index = state.indexWhere((n) => n.id == id);
    if (index == -1) return;
    final trimmedTitle = title?.trim();
    final named = trimmedTitle == null || trimmedTitle.isEmpty
        ? null
        : trimmedTitle;
    final now = ref.read(clockProvider).nowUtc();
    _dao.update(
      id,
      body: body,
      title: named,
      projectId: projectId,
      updatedAt: now,
    );
    final updated = state[index].copyWith(
      body: body,
      title: named,
      clearTitle: named == null,
      projectId: projectId,
      clearProjectId: projectId == null,
      updatedAt: now,
    );
    state = [...state]..[index] = updated;
  }

  /// Files [id] under [projectId], or unfiles it when that is null. The one
  /// write that leaves `updated_at` alone: filing is not editing.
  void setProject(String id, String? projectId) {
    final index = state.indexWhere((n) => n.id == id);
    if (index == -1) return;
    _dao.setProject(id, projectId);
    state = [...state]..[index] = state[index].copyWith(
      projectId: projectId,
      clearProjectId: projectId == null,
    );
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

/// Which project's notes the panel is showing. Its own controller rather than
/// one shared with Todos: the two panels are looked at for different reasons,
/// and a filter set in one silently narrowing the other is a surprise nobody
/// asked for.
class NoteScopeController extends Notifier<ProjectScope> {
  @override
  ProjectScope build() => ProjectScope.all;

  void select(ProjectScope scope) => state = scope;
}

final noteScopeProvider = NotifierProvider<NoteScopeController, ProjectScope>(
  NoteScopeController.new,
);
