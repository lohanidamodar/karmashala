import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_notes/karmashala_notes.dart';
import 'package:karmashala_notes/store.dart';
import 'package:karmashala_store/database.dart';

import 'filing_lookup.dart';

/// The notes domain at the server: validates, writes the `notes` table and
/// says what changed.
class NotesHandler {
  NotesHandler(AppDatabase db, this._filing, this._now) : _dao = NoteDao(db);

  final NoteDao _dao;
  final FilingLookup _filing;
  final DateTime Function() _now;

  List<Note> list(NotesList request) => _dao.list(sessionId: request.sessionId);

  Note capture(NoteCapture request, List<DataChange> changes) {
    final problem = recordIdProblem(request.id);
    if (problem != null) throw DataRefused.invalid('notes.capture: $problem');
    if (_dao.getById(request.id) != null) {
      throw DataRefused.invalid('a note with id ${request.id} already exists');
    }
    final sourceSession = request.sourceSessionId;
    final sourceRepository =
        request.sourceRepositoryId ??
        (sourceSession == null
            ? null
            : _filing.repositoryOfSession(sourceSession));
    final projectId =
        request.projectId ??
        (request.inheritProject && sourceRepository != null
            ? _filing.projectOfRepository(sourceRepository)
            : null);
    _requireProject(projectId);
    final now = _now();
    final note = Note(
      id: request.id,
      title: noteTitleOf(request.title),
      body: request.body,
      projectId: projectId,
      sourceSessionId: sourceSession,
      sourceRepositoryId: sourceRepository,
      sourceMessageOrdinal: request.sourceMessageOrdinal,
      sourceMessageRole: request.sourceMessageRole,
      createdAt: now,
      updatedAt: now,
    );
    _dao.insert(note);
    changes.add(NoteChanged(note));
    return note;
  }

  Note edit(NoteEdit request, List<DataChange> changes) {
    _existing(request.id);
    _requireProject(request.projectId);
    _dao.update(
      request.id,
      body: request.body,
      title: noteTitleOf(request.title),
      projectId: request.projectId,
      updatedAt: _now(),
    );
    return _changed(request.id, changes);
  }

  Note file(NoteFile request, List<DataChange> changes) {
    _existing(request.id);
    _requireProject(request.projectId);
    _dao.setProject(request.id, request.projectId);
    return _changed(request.id, changes);
  }

  DataAck delete(NoteDelete request, List<DataChange> changes) {
    _existing(request.id);
    _dao.delete(request.id);
    changes.add(NoteRemoved(request.id));
    return const DataAck();
  }

  Note _existing(String id) =>
      _dao.getById(id) ?? (throw DataRefused.notFound('no note with id $id'));

  Note _changed(String id, List<DataChange> changes) {
    final note = _existing(id);
    changes.add(NoteChanged(note));
    return note;
  }

  void _requireProject(String? projectId) {
    if (projectId != null && !_filing.projectExists(projectId)) {
      throw DataRefused.notFound('no project with id $projectId');
    }
  }
}
