import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_notes/karmashala_notes.dart' show recordIdProblem;
import 'package:karmashala_notes/store.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_store/database.dart';

/// The workspace domain at the server — contexts, projects, their checkouts
/// and the saved Explorer sections: validates, applies the rules in
/// `karmashala_projects`, writes, and says what changed — including what a
/// write did to other domains' rows (a deleted project unfiles its notes and
/// todos).
class WorkspaceHandler {
  WorkspaceHandler(
    this._db,
    this._now,
    this._newId, {
    List<DataChange> Function() Function(List<String> checkoutIds)?
    checkoutsGoing,
  }) : _checkoutsGoing = checkoutsGoing,
       _workspaces = WorkspaceDao(_db),
       _projects = ProjectDao(_db),
       _repositories = RepositoryDao(_db),
       _sections = SectionDao(_db),
       _notes = NoteDao(_db),
       _todos = TodoDao(_db);

  final AppDatabase _db;
  final DateTime Function() _now;
  final String Function() _newId;

  /// What deleting checkouts takes from the sessions domain, read before
  /// the delete and told after it.
  final List<DataChange> Function() Function(List<String> checkoutIds)?
  _checkoutsGoing;
  final WorkspaceDao _workspaces;
  final ProjectDao _projects;
  final RepositoryDao _repositories;
  final SectionDao _sections;
  final NoteDao _notes;
  final TodoDao _todos;

  WorkspaceSnapshot list() => WorkspaceSnapshot(
    workspaces: _workspaces.getAll(),
    projects: _projects.getAll(),
    repositories: _repositories.getAll(),
    sections: _sections.getAll(),
  );

  // Contexts.

  Workspace putWorkspace(WorkspacePut request, List<DataChange> changes) {
    final problem = recordIdProblem(request.id);
    if (problem != null) throw DataRefused.invalid('workspaces.put: $problem');
    final name =
        rowNameOf(request.workspaceName) ??
        (throw const DataRefused.invalid('A context needs a name.'));
    for (final other in _workspaces.getAll()) {
      if (other.id != request.id && sameContextName(other.name, name)) {
        throw DataRefused.invalid('A context called "$name" already exists.');
      }
    }
    final description = descriptionOf(request.description);
    if (_workspaces.getById(request.id) == null) {
      _workspaces.insert(
        Workspace(
          id: request.id,
          name: name,
          description: description,
          createdAt: _now(),
        ),
      );
    } else {
      _workspaces.updateDetails(
        request.id,
        name: name,
        description: description,
      );
    }
    return _workspaceChanged(request.id, changes);
  }

  Workspace setColor(WorkspaceSetColor request, List<DataChange> changes) {
    _workspace(request.id);
    _workspaces.updateColor(request.id, request.color);
    return _workspaceChanged(request.id, changes);
  }

  DataAck deleteWorkspace(WorkspaceDelete request, List<DataChange> changes) {
    _workspace(request.id);
    final filed = _projects.inWorkspace(request.id);
    _workspaces.delete(request.id);
    changes.add(WorkspaceRemoved(request.id));
    // `ON DELETE SET NULL`: the projects stay, unassigned.
    for (final project in filed) {
      changes.add(ProjectChanged(_project(project.id)));
    }
    return const DataAck();
  }

  // Projects.

  ProjectCheckouts createProject(
    ProjectCreate request,
    List<DataChange> changes,
  ) {
    final name =
        rowNameOf(request.projectName) ??
        (throw const DataRefused.invalid('A project needs a name.'));
    _requireEnvironment(request.root.environmentId);
    final workspaceId = request.workspaceId;
    if (workspaceId != null) _workspace(workspaceId);
    final project = Project(
      id: _newId(),
      name: name,
      root: request.root,
      createdAt: _now(),
      workspaceId: workspaceId,
    );
    final checkouts = checkoutsForNewProject(
      project,
      request.found,
      newId: _newId,
    );
    for (final checkout in checkouts) {
      _requireEnvironment(checkout.environmentId);
    }
    _db.transaction(() {
      _projects.insert(project);
      checkouts.forEach(_repositories.insert);
    });
    changes
      ..add(ProjectChanged(project))
      ..addAll(checkouts.map(RepositoryChanged.new));
    return ProjectCheckouts(project, checkouts);
  }

  ProjectUpdated updateProject(
    ProjectUpdate request,
    List<DataChange> changes,
  ) {
    final project = _project(request.id);
    final String? name;
    if (request.projectName case final requested?) {
      name =
          rowNameOf(requested) ??
          (throw const DataRefused.invalid('A project needs a name.'));
    } else {
      name = null;
    }
    final root = request.root;
    final moving = root != null && rootMoves(project.root, root);
    if (moving) _requireEnvironment(root.environmentId);

    var rebased = const <Repository>[];
    var leftBehind = const <Repository>[];
    var added = const <Repository>[];
    _db.transaction(() {
      if (moving) {
        final existing = _repositories.getByProject(project.id);
        (:rebased, :leftBehind) = rebaseCheckouts(project.root, root, existing);
        rebased.forEach(_repositories.update);
        added = checkoutsToAdd(
          project,
          [...rebased, ...leftBehind],
          request.found,
          newId: _newId,
          now: _now(),
        );
        added.forEach(_repositories.insert);
      }
      // A default that no longer names one of this project's checkouts falls
      // back to the picker's first row, the rule for one that never chose.
      final requested = request.clearDefaultRepository
          ? null
          : (request.defaultRepositoryId ?? project.defaultRepositoryId);
      final owned = _repositories
          .getByProject(project.id)
          .any((repository) => repository.id == requested);
      _projects.update(
        Project(
          id: project.id,
          name: name ?? project.name,
          root: root ?? project.root,
          createdAt: project.createdAt,
          workspaceId: project.workspaceId,
          defaultRepositoryId: owned ? requested : null,
        ),
      );
    });
    final updated = _project(project.id);
    changes
      ..add(ProjectChanged(updated))
      ..addAll([...rebased, ...added].map(RepositoryChanged.new));
    return ProjectUpdated(
      project: updated,
      rebased: rebased,
      leftBehind: leftBehind,
      discovered: added,
    );
  }

  DataAck fileProjects(ProjectsFile request, List<DataChange> changes) {
    for (final MapEntry(key: projectId, value: workspaceId)
        in request.placements.entries) {
      _project(projectId);
      if (workspaceId != null) _workspace(workspaceId);
    }
    _db.transaction(() => request.placements.forEach(_projects.setWorkspace));
    for (final projectId in request.placements.keys) {
      changes.add(ProjectChanged(_project(projectId)));
    }
    return const DataAck();
  }

  /// One operation: the project, its checkouts and — by the schema's
  /// cascades — everything recorded against them go; its notes and todos
  /// stay, unfiled, and every subscribed client is told all of it.
  DataAck deleteProject(ProjectDelete request, List<DataChange> changes) {
    _project(request.id);
    final checkouts = _repositories.getByProject(request.id);
    final notes = [
      for (final note in _notes.list())
        if (note.projectId == request.id) note.id,
    ];
    final todos = [
      for (final todo in _todos.list())
        if (todo.projectId == request.id) todo.id,
    ];
    final sessionsGoing = _checkoutsGoing?.call([
      for (final checkout in checkouts) checkout.id,
    ]);
    _projects.delete(request.id);
    changes
      ..add(ProjectRemoved(request.id))
      ..addAll(checkouts.map((checkout) => RepositoryRemoved(checkout.id)))
      ..addAll(sessionsGoing?.call() ?? const []);
    for (final id in notes) {
      if (_notes.getById(id) case final note?) changes.add(NoteChanged(note));
    }
    for (final id in todos) {
      if (_todos.getById(id) case final todo?) changes.add(TodoChanged(todo));
    }
    return const DataAck();
  }

  List<String> projectsUsing(ProjectsUsingEnvironment request) =>
      _projects.namesUsingEnvironment(request.environmentId);

  // Checkouts.

  List<Repository> addCheckouts(
    CheckoutsAdd request,
    List<DataChange> changes,
  ) {
    final project = _project(request.projectId);
    final added = checkoutsToAdd(
      project,
      _repositories.getByProject(project.id),
      request.found,
      newId: _newId,
      orRoot: request.orRoot,
      now: _now(),
    );
    for (final checkout in added) {
      _requireEnvironment(checkout.environmentId);
    }
    _db.transaction(() => added.forEach(_repositories.insert));
    changes.addAll(added.map(RepositoryChanged.new));
    return added;
  }

  /// Deleting a checkout cascades into session history, so only one nothing
  /// recorded points at goes; the rest are answered with what keeps them.
  Map<String, int> retireCheckouts(
    CheckoutsRetire request,
    List<DataChange> changes,
  ) {
    final answer = <String, int>{};
    final touched = <String>{};
    for (final id in request.ids) {
      final checkout = _repositories.getById(id);
      if (checkout == null) continue;
      final records = _repositories.historyReferenceCount(id);
      answer[id] = records;
      if (records > 0) continue;
      final project = _projects.getById(checkout.projectId);
      _repositories.delete(id);
      changes.add(RepositoryRemoved(id));
      // `default_repository_id` is `ON DELETE SET NULL`.
      if (project?.defaultRepositoryId == id) touched.add(project!.id);
    }
    for (final projectId in touched) {
      changes.add(ProjectChanged(_project(projectId)));
    }
    return answer;
  }

  List<Repository> identifyCheckouts(
    CheckoutsIdentify request,
    List<DataChange> changes,
  ) {
    final changed = <Repository>[];
    for (final row in _repositories.getByLocation(request.path)) {
      if (row.canonicalId == request.canonicalId) continue;
      _repositories.updateCanonicalId(row.id, request.canonicalId);
      changed.add(_repositories.getById(row.id)!);
    }
    changes.addAll(changed.map(RepositoryChanged.new));
    return changed;
  }

  // Sections.

  StoredSection putSection(SectionPut request, List<DataChange> changes) {
    final section = request.section;
    final problem = recordIdProblem(section.id);
    if (problem != null) throw DataRefused.invalid('sections.put: $problem');
    final name =
        rowNameOf(section.name) ??
        (throw const DataRefused.invalid('a section needs a name'));
    if (section.kind.isEmpty) {
      throw const DataRefused.invalid('a section needs a rule');
    }
    final existing = _sections.getById(section.id);
    if (existing != null && existing.kind == StoredSection.pinnedKind) {
      // The built-in group only folds and unfolds.
      if (section.copyWith(collapsed: existing.collapsed) != existing) {
        throw const DataRefused(
          DataRefusalCode.reserved,
          'the Pinned section can only be folded',
        );
      }
    } else if (section.kind == StoredSection.pinnedKind) {
      throw const DataRefused(
        DataRefusalCode.reserved,
        'there is one Pinned section, and it is built in',
      );
    }
    _sections.put(
      StoredSection(
        id: section.id,
        name: name,
        kind: section.kind,
        pattern: section.pattern,
        position: section.position,
        collapsed: section.collapsed,
        members: section.kind == StoredSection.manualKind
            ? section.members
            : const {},
      ),
    );
    final stored = _sections.getById(section.id)!;
    changes.add(SectionChanged(stored));
    return stored;
  }

  List<StoredSection> reorderSections(
    SectionsReorder request,
    List<DataChange> changes,
  ) {
    final before = {for (final s in _sections.getAll()) s.id: s};
    _sections.reorder(request.ids);
    final after = _sections.getAll();
    for (final section in after) {
      if (before[section.id] != section) changes.add(SectionChanged(section));
    }
    return after;
  }

  DataAck deleteSection(SectionDelete request, List<DataChange> changes) {
    final section =
        _sections.getById(request.id) ??
        (throw DataRefused.notFound('no section with id ${request.id}'));
    if (section.kind == StoredSection.pinnedKind) {
      throw const DataRefused(
        DataRefusalCode.reserved,
        'the Pinned section is built in',
      );
    }
    _sections.delete(request.id);
    changes.add(SectionRemoved(request.id));
    return const DataAck();
  }

  Workspace _workspace(String id) =>
      _workspaces.getById(id) ??
      (throw DataRefused.notFound('no context with id $id'));

  Workspace _workspaceChanged(String id, List<DataChange> changes) {
    final workspace = _workspace(id);
    changes.add(WorkspaceChanged(workspace));
    return workspace;
  }

  Project _project(String id) =>
      _projects.getById(id) ??
      (throw DataRefused.notFound('no project with id $id'));

  void _requireEnvironment(String environmentId) {
    final known = _db.query(
      'SELECT 1 FROM execution_environments WHERE id = ?;',
      [environmentId],
    );
    if (known.isEmpty) {
      throw DataRefused.notFound('no environment with id $environmentId');
    }
  }
}
