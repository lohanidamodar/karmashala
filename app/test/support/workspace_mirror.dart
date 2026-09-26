import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import 'fake_data_server.dart';

/// **Transitional — goes with the conversation index (slice 1f).**
///
/// The app reads everything but the conversation index from its data client
/// (in tests, the [FakeDataServer]). The index still lives in the database the
/// app opens, and its queries join the rows it indexes — sessions, their
/// checkouts and projects, installations. [mirrorInto] copies those rows the
/// fake writes into [db] for the index's tests; nothing else reads them there.
///
/// The one file under `test/` that may name the moved domains' DAOs
/// (`direct_database_guard_test.dart` holds it there).
/// The fake server whose rows are mirrored into [db].
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
    final environments = ExecutionEnvironmentDao(db);
    final installations = AgentInstallationDao(db);
    // Best-effort, like the sessions below: a row whose own foreign keys the
    // test never seeded is simply not mirrored.
    void applyHost(HostsDomainChange change) {
      try {
        switch (change) {
          case EnvironmentChanged(:final environment):
            environments.upsert(environment);
          case EnvironmentRemoved(:final id):
            environments.delete(id);
          case InstallationChanged(:final installation):
            if (installations.getById(installation.id) == null) {
              installations.insert(installation);
            } else {
              installations
                ..updatePath(
                  installation.id,
                  installation.executable.path,
                  byUser: installation.executableByUser,
                )
                ..recordVersion(
                  installation.id,
                  installation.version,
                  readAt: installation.versionReadAt ?? installation.createdAt,
                );
            }
          case InstallationRemoved(:final id):
            installations.deleteIfUnreferenced(id);
          default:
            break;
        }
      } on Object {
        // Not mirrored; see above.
      }
    }

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

    environmentRows.getAll().map(EnvironmentChanged.new).forEach(applyHost);
    installationRows.getAll().map(InstallationChanged.new).forEach(applyHost);
    workspaceRows.getAll().map(WorkspaceChanged.new).forEach(apply);
    projectRows.getAll().map(ProjectChanged.new).forEach(apply);
    repositoryRows.getAll().map(RepositoryChanged.new).forEach(apply);
    sectionRows.getAll().map(SectionChanged.new).forEach(apply);
    sessionRows.getAll().map(SessionRowChanged.new).forEach(applySession);
    importedRows.getAll().map(ImportedChanged.new).forEach(applySession);
    hostRowListeners.add(applyHost);
    rowListeners.add(apply);
    sessionRowListeners.add(applySession);
    return this;
  }
}
