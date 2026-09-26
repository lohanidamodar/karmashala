import 'package:karmashala_data_protocol/karmashala_data_protocol.dart' as data;
import 'package:karmashala_notes/karmashala_notes.dart';

import '../../../core/data/data_client.dart';

/// Notes as the server keeps them: read from this app's copy, written
/// through the server. Each write lands in the copy at once, and the
/// server's answer — the note as stored — replaces it.
class NotesRepository {
  NotesRepository(this._client);

  final DataClient _client;

  /// Fires after the notes changed, from here or another client.
  Stream<void> get changes => _client.notes.changes;

  /// Every note, newest first.
  List<Note> list() => [..._client.notes.values]..sort(compareNotes);

  Note? byId(String id) => _client.notes[id];

  /// Keeps [draft] — its id, body and origin — filing it by the server's
  /// rule when [inheritProject] and it names no project.
  Future<Note> capture(Note draft, {required bool inheritProject}) {
    _client.notes.setLocal(draft.id, draft);
    return _write(
      data.NoteCapture(
        id: draft.id,
        body: draft.body,
        title: draft.title,
        projectId: draft.projectId,
        inheritProject: inheritProject,
        sourceSessionId: draft.sourceSessionId,
        sourceRepositoryId: draft.sourceRepositoryId,
        sourceMessageOrdinal: draft.sourceMessageOrdinal,
        sourceMessageRole: draft.sourceMessageRole,
      ),
    );
  }

  Future<Note> edit(
    String id, {
    required String body,
    required String? title,
    required String? projectId,
  }) {
    final note = byId(id);
    if (note != null) {
      final named = noteTitleOf(title);
      _client.notes.setLocal(
        id,
        note.copyWith(
          body: body,
          title: named,
          clearTitle: named == null,
          projectId: projectId,
          clearProjectId: projectId == null,
        ),
      );
    }
    return _write(
      data.NoteEdit(id: id, body: body, title: title, projectId: projectId),
    );
  }

  Future<Note> file(String id, String? projectId) {
    final note = byId(id);
    if (note != null) {
      _client.notes.setLocal(
        id,
        note.copyWith(projectId: projectId, clearProjectId: projectId == null),
      );
    }
    return _write(data.NoteFile(id: id, projectId: projectId));
  }

  Future<void> delete(String id) {
    _client.notes.setLocal(id, null);
    return _client.write(
      data.NoteDelete(id),
      domain: DataDomain.notes,
      apply: (_, revision) => _client.notes.applyAt(id, null, revision),
    );
  }

  Future<Note> _write(data.DataRequest<Note> request) => _client.write(
    request,
    domain: DataDomain.notes,
    apply: (note, revision) => _client.notes.applyAt(note.id, note, revision),
  );
}
