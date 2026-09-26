import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

import 'fake_data_server.dart';

/// **Transitional — goes when sessions move to the server (slice 1c).**
///
/// The app reads the workspace only from its data client (in tests, the
/// [FakeDataServer]). But sessions and their records are still in the test's
/// database, and their foreign keys — and a few queries not moved yet
/// (session placement, the conversation index) — reach the workspace tables
/// there. [mirrorInto] copies every workspace row the fake writes into [db],
/// so those rows exist; nothing in the app reads them from [db].
///
/// The one file under `test/` that may name the workspace DAOs
/// (`direct_database_guard_test.dart` holds it there).
extension WorkspaceMirror on FakeDataServer {
  /// From now on, and for the rows already seeded.
  FakeDataServer mirrorInto(AppDatabase db) {
    final workspaces = WorkspaceDao(db);
    final projects = ProjectDao(db);
    final repositories = RepositoryDao(db);
    final sections = SectionDao(db);
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

    workspaceRows.getAll().map(WorkspaceChanged.new).forEach(apply);
    projectRows.getAll().map(ProjectChanged.new).forEach(apply);
    repositoryRows.getAll().map(RepositoryChanged.new).forEach(apply);
    sectionRows.getAll().map(SectionChanged.new).forEach(apply);
    rowListeners.add(apply);
    return this;
  }
}
