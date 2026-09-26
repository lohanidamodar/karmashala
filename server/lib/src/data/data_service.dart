import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_store/database.dart';

import '../domain/uuid.dart';
import 'filing_lookup.dart';
import 'notes_handler.dart';
import 'preferences_handler.dart';
import 'todos_handler.dart';
import 'workspace_handler.dart';

/// The server's data API over its store: every client's reads and writes of
/// notes, todos, preferences and the workspace, whatever link carries them. The only writer
/// of those tables; each write is numbered ([revision]) and told to every
/// other subscribed [DataSession].
class DataService {
  DataService(
    AppDatabase database, {
    DateTime Function()? clock,
    String Function()? newId,
  }) : _now = clock ?? _utcNow {
    final filing = FilingLookup(database);
    _notes = NotesHandler(database, filing, _now);
    _todos = TodosHandler(database, filing, _now);
    _preferences = PreferencesHandler(database);
    _workspace = WorkspaceHandler(database, _now, newId ?? newUuid);
  }

  static DateTime _utcNow() => DateTime.now().toUtc();

  final DateTime Function() _now;
  late final NotesHandler _notes;
  late final TodosHandler _todos;
  late final PreferencesHandler _preferences;
  late final WorkspaceHandler _workspace;
  final _sessions = <DataSession>{};
  var _revision = 0;

  /// The number of the last write, since this service started.
  int get revision => _revision;

  /// One client link. [deliver] gets the changes other links make once the
  /// client has sent [DataSubscribe].
  DataSession open(void Function(DataChanges changes) deliver) {
    final session = DataSession._(this, deliver);
    _sessions.add(session);
    return session;
  }

  DataReply<R> _handle<R>(DataSession origin, DataRequest<R> request) {
    final changes = <DataChange>[];
    final Object? result;
    try {
      result = switch (request) {
        DataSubscribe() => origin._subscribe(),
        final NotesList r => _notes.list(r),
        final NoteCapture r => _notes.capture(r, changes),
        final NoteEdit r => _notes.edit(r, changes),
        final NoteFile r => _notes.file(r, changes),
        final NoteDelete r => _notes.delete(r, changes),
        TodosList() => _todos.list(),
        final TodoAdd r => _todos.add(r, changes),
        final TodoSetDone r => _todos.setDone(r, changes),
        final TodoEdit r => _todos.edit(r, changes),
        final TodoFile r => _todos.file(r, changes),
        final TodoMove r => _todos.move(r, changes),
        final TodoDelete r => _todos.delete(r, changes),
        final TodosClearDone r => _todos.clearDone(r, changes),
        PreferencesGet() => _preferences.all(),
        final PreferenceSet r => _preferences.set(r, changes),
        final PreferenceRemove r => _preferences.remove(r, changes),
        WorkspaceList() => _workspace.list(),
        final WorkspacePut r => _workspace.putWorkspace(r, changes),
        final WorkspaceSetColor r => _workspace.setColor(r, changes),
        final WorkspaceDelete r => _workspace.deleteWorkspace(r, changes),
        final ProjectCreate r => _workspace.createProject(r, changes),
        final ProjectUpdate r => _workspace.updateProject(r, changes),
        final ProjectsFile r => _workspace.fileProjects(r, changes),
        final ProjectDelete r => _workspace.deleteProject(r, changes),
        final ProjectsUsingEnvironment r => _workspace.projectsUsing(r),
        final CheckoutsAdd r => _workspace.addCheckouts(r, changes),
        final CheckoutsRetire r => _workspace.retireCheckouts(r, changes),
        final CheckoutsIdentify r => _workspace.identifyCheckouts(r, changes),
        final SectionPut r => _workspace.putSection(r, changes),
        final SectionsReorder r => _workspace.reorderSections(r, changes),
        final SectionDelete r => _workspace.deleteSection(r, changes),
      };
    } on DataRefused {
      rethrow;
    } on Object catch (error) {
      throw DataRefused(
        DataRefusalCode.failed,
        '${request.kind} failed: $error',
      );
    }
    if (changes.isEmpty) return DataReply(result as R, _revision);
    final batch = DataChanges(++_revision, List.unmodifiable(changes));
    for (final session in _sessions) {
      if (session != origin && session._subscribed) session._deliver(batch);
    }
    return DataReply(result as R, _revision, batch.changes);
  }
}

/// One client's link to the [DataService].
class DataSession {
  DataSession._(this._service, this._deliver);

  final DataService _service;
  final void Function(DataChanges changes) _deliver;
  var _subscribed = false;

  /// Answers [request] now, or throws [DataRefused].
  DataReply<R> handle<R>(DataRequest<R> request) =>
      _service._handle(this, request);

  /// Answers the envelope [json] with the envelope to send back.
  Map<String, Object?> handleJson(Map<String, Object?> json) {
    final read = DataEnvelope.readRequest(json);
    final request = read.request;
    if (request == null) return DataEnvelope.refusal(read.id, read.refusal!);
    try {
      return _answer(read.id, request);
    } on DataRefused catch (refusal) {
      return DataEnvelope.refusal(read.id, refusal);
    }
  }

  Map<String, Object?> _answer<R>(int id, DataRequest<R> request) {
    return DataEnvelope.answer(id, request, handle(request));
  }

  void close() => _service._sessions.remove(this);

  DataAck _subscribe() {
    _subscribed = true;
    return const DataAck();
  }
}
