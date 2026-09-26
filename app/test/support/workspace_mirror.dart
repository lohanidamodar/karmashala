import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import 'fake_data_server.dart';

/// **Transitional — goes when the last table that points at the workspace
/// or at sessions moves to the server (slices 1d–1f).**
///
/// The app reads the workspace and sessions only from its data client (in
/// tests, the [FakeDataServer]). But tables not moved yet are still in the
/// test's database, and their foreign keys — and a few queries not moved yet
/// (the conversation index's joins, scheduled resumes, automation origins,
/// agent installations `ON DELETE RESTRICT`) — reach the workspace and
/// session rows there. [mirrorInto] copies every workspace and session row
/// the fake writes into [db], so those rows exist; nothing in the app reads
/// them from [db].
///
/// The one file under `test/` that may name the workspace and sessions DAOs
/// (`direct_database_guard_test.dart` holds it there).
/// The fake server whose rows are mirrored into [db] — the server a test that
/// holds only its database seeds and reads (`mirroredServer(db).sessionRows`).
/// Never the database itself: [db] only names which server.
FakeDataServer mirroredServer(AppDatabase db) =>
    _mirrored[db] ??
    (throw StateError('no fake server is mirrored into that database'));

final _mirrored = Expando<FakeDataServer>();

extension WorkspaceMirror on FakeDataServer {
  /// From now on, and for the rows already seeded.
  FakeDataServer mirrorInto(AppDatabase db) {
    _mirrored[db] = this;
    final workspaces = WorkspaceDao(db);
    final projects = ProjectDao(db);
    final repositories = RepositoryDao(db);
    final sections = SectionDao(db);
    final sessions = SessionDao(db);
    final imported = ImportedSessionDao(db);
    void apply(RowChange change) {
      switch (change) {
        case WorkspaceChanged(:final workspace):
          workspaces.getById(workspace.id) == null
              ? workspaces.insert(workspace)
              : (workspaces
                  ..updateDetails(
                    workspace.id,
                    name: workspace.name,
                    description: workspace.description,
                  )
                  ..updateColor(workspace.id, workspace.color));
        case ProjectChanged(:final project):
          projects.getById(project.id) == null
              ? projects.insert(project)
              : projects.update(project);
        case RepositoryChanged(:final repository):
          repositories.getById(repository.id) == null
              ? repositories.insert(repository)
              : repositories.update(repository);
        case SectionChanged(:final section):
          sections.put(section);
        case WorkspaceRemoved(:final id):
          workspaces.delete(id);
        case ProjectRemoved(:final id):
          projects.delete(id);
        case RepositoryRemoved(:final id):
          if (repositories.getById(id) != null) repositories.delete(id);
        case SectionRemoved(:final id):
          sections.delete(id);
      }
    }

    // Best-effort: a row whose own foreign keys the test never seeded (an
    // agent installation) is simply not mirrored — only the tables that point
    // at it need it, and a test of those seeds what they need.
    void applySession(SessionDomainChange change) {
      try {
        switch (change) {
          case SessionRowChanged(:final session):
            sessions.getById(session.id) == null
                ? sessions.insert(session)
                : sessions.write(session);
          case SessionRowRemoved(:final id):
            sessions.delete(id);
          case ImportedChanged(:final session):
            if (imported.getById(session.id) == null) {
              imported.insertIfAbsent(session);
            } else if (session.title case final title?) {
              imported.updateTitle(session.id, title);
            }
          case ImportedRemoved(:final id):
            imported.delete(id);
          default:
            break;
        }
      } on Object {
        // Not mirrored; see above.
      }
    }

    workspaceRows.getAll().map(WorkspaceChanged.new).forEach(apply);
    projectRows.getAll().map(ProjectChanged.new).forEach(apply);
    repositoryRows.getAll().map(RepositoryChanged.new).forEach(apply);
    sectionRows.getAll().map(SectionChanged.new).forEach(apply);
    sessionRows.getAll().map(SessionRowChanged.new).forEach(applySession);
    importedRows.getAll().map(ImportedChanged.new).forEach(applySession);
    rowListeners.add(apply);
    sessionRowListeners.add(applySession);
    return this;
  }
}
