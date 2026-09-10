import 'package:riverpod/riverpod.dart';

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

/// Every note, newest first, kept in memory so the panel rebuilds on a write —
/// notes are few and small, and a resize must not re-read the table per frame.
class NotesController extends Notifier<List<Note>> {
  @override
  List<Note> build() => ref.watch(noteDaoProvider).list();

  NoteDao get _dao => ref.read(noteDaoProvider);

  /// Keeps [body] **exactly as given**; nothing here trims a message into a
  /// gist. [inheritProjectFromSource] is how a caller says *file this under nothing*.
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

  /// The project a note captured from [repositoryId] belongs to — a lookup, not
  /// a guess, since a repository belongs to exactly one project.
  String? _projectOf(String? repositoryId) => repositoryId == null
      ? null
      : ref.read(repositoryDaoProvider).getById(repositoryId)?.projectId;

  /// Applies the user's edit. An empty title clears it; [projectId] null means
  /// "no project", a choice, so it is the one field an edit can clear.
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
/// one shared with Todos: a filter set in one must not narrow the other.
class NoteScopeController extends Notifier<ProjectScope> {
  @override
  ProjectScope build() => ProjectScope.all;

  void select(ProjectScope scope) => state = scope;
}

final noteScopeProvider = NotifierProvider<NoteScopeController, ProjectScope>(
  NoteScopeController.new,
);
