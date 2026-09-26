import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:karmashala_core/logging.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../settings/application/settings_controller.dart';
import '../../todos/domain/project_scope.dart';
import '../data/notes_repository.dart';

final notesRepositoryProvider = Provider<NotesRepository>(
  (ref) => NotesRepository(ref.watch(dataClientProvider)),
);

/// Whether the Notes feature is on. One reading, so the capture affordance and
/// the browse surface cannot disagree about whether the user asked for this.
final notesEnabledProvider = Provider<bool>(
  (ref) => ref.watch(settingsControllerProvider.select((s) => s.notesEnabled)),
);

final _log = AppLogger.named('notes');

/// Every note, newest first, as the server keeps them. Live: a note another
/// client writes arrives here without asking.
class NotesController extends Notifier<List<Note>> {
  @override
  List<Note> build() {
    final repository = ref.watch(notesRepositoryProvider);
    final rows = repository.list();
    final changes = repository.changes.listen((_) {
      final next = repository.list();
      if (!listEquals(next, state)) state = next;
    });
    ref.onDispose(changes.cancel);
    return rows;
  }

  NotesRepository get _repository => ref.read(notesRepositoryProvider);

  /// Keeps [body] **exactly as given**; nothing here trims a message into a
  /// gist. [inheritProjectFromSource] is how a caller says *file this under
  /// nothing*; otherwise the server files it under the project its source
  /// belongs to. Answers the note at once, as it will be stored.
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
    final (draft, stored) = _capture(
      body: body,
      title: title,
      projectId: projectId,
      inherit: inheritProjectFromSource,
      sourceSessionId: sourceSessionId,
      sourceRepositoryId: sourceRepositoryId,
      sourceMessageOrdinal: sourceMessageOrdinal,
      sourceMessageRole: sourceMessageRole,
    );
    _logged('Keeping a note', stored);
    return draft;
  }

  /// [capture], answering the note as the server stored it — its filing
  /// decided there. Throws `DataRefused`.
  Future<Note> captureStored({
    required String body,
    String? title,
    String? projectId,
    bool inheritProjectFromSource = true,
    String? sourceSessionId,
    String? sourceRepositoryId,
  }) => _capture(
    body: body,
    title: title,
    projectId: projectId,
    inherit: inheritProjectFromSource,
    sourceSessionId: sourceSessionId,
    sourceRepositoryId: sourceRepositoryId,
  ).$2;

  (Note, Future<Note>) _capture({
    required String body,
    String? title,
    String? projectId,
    required bool inherit,
    String? sourceSessionId,
    String? sourceRepositoryId,
    int? sourceMessageOrdinal,
    String? sourceMessageRole,
  }) {
    final now = ref.read(clockProvider).nowUtc();
    final draft = Note(
      id: _newId(now),
      title: noteTitleOf(title),
      body: body,
      projectId: projectId,
      sourceSessionId: sourceSessionId,
      sourceRepositoryId: sourceRepositoryId,
      sourceMessageOrdinal: sourceMessageOrdinal,
      sourceMessageRole: sourceMessageRole,
      createdAt: now,
      updatedAt: now,
    );
    return (draft, _repository.capture(draft, inheritProject: inherit));
  }

  /// Applies the user's edit. An empty title clears it; [projectId] null means
  /// "no project", a choice, so it is the one field an edit can clear.
  void edit(
    String id, {
    required String body,
    String? title,
    String? projectId,
  }) {
    if (_repository.byId(id) == null) return;
    _logged(
      'Saving a note',
      _repository.edit(id, body: body, title: title, projectId: projectId),
    );
  }

  /// Files [id] under [projectId], or unfiles it when that is null. The one
  /// write that leaves `updated_at` alone: filing is not editing.
  void setProject(String id, String? projectId) {
    if (_repository.byId(id) == null) return;
    _logged('Filing a note', _repository.file(id, projectId));
  }

  void delete(String id) => _logged('Deleting a note', _repository.delete(id));

  /// [delete], answering how the server took it. Throws `DataRefused`
  /// (`notFound` for a note that is not there).
  Future<void> deleteStored(String id) => _repository.delete(id);

  void _logged(String what, Future<Object?> write) => unawaited(
    write.then<void>(
      (_) {},
      onError: (Object error) => _log.warning('$what failed: $error'),
    ),
  );

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
