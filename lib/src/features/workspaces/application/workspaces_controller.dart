import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../projects/application/project_providers.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/domain/project.dart';
import '../domain/workspace.dart';
import '../domain/workspace_scope.dart';
import 'workspace_providers.dart';

/// Raised when a name would produce two contexts a picker cannot tell apart.
class DuplicateWorkspaceName implements Exception {
  const DuplicateWorkspaceName(this.name);
  final String name;
  @override
  String toString() => 'A context called "$name" already exists.';
}

/// The user's contexts, and the four verbs over them: create, rename, delete,
/// assign. Reads are synchronous (SQLite), so the state is the plain list.
class WorkspacesController extends Notifier<List<Workspace>> {
  @override
  List<Workspace> build() => ref.watch(workspaceDaoProvider).getAll();

  Workspace create(String name, {String? description}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('A context needs a name.');
    _rejectDuplicate(trimmed, exceptId: null);
    final workspace = Workspace(
      id: ref.read(idGeneratorProvider).newId(),
      name: trimmed,
      description: _clean(description),
      createdAt: ref.read(clockProvider).nowUtc(),
    );
    ref.read(workspaceDaoProvider).insert(workspace);
    _refresh();
    return workspace;
  }

  /// The name and the description together, because they are edited together.
  /// A blank description **clears** it — a form that can only add cannot correct.
  void edit(String id, {required String name, String? description}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('A context needs a name.');
    _rejectDuplicate(trimmed, exceptId: id);
    ref
        .read(workspaceDaoProvider)
        .updateDetails(id, name: trimmed, description: _clean(description));
    _refresh();
  }

  /// The name alone, leaving whatever description the context already had.
  void rename(String id, String name) => edit(
    id,
    name: name,
    description: state.where((w) => w.id == id).firstOrNull?.description,
  );

  /// Deletes the context. **Its projects are kept** and become unassigned, by
  /// the schema's `ON DELETE SET NULL`; this only refreshes the project list.
  void delete(String id) {
    ref.read(workspaceDaoProvider).delete(id);
    // Whatever was being shown, showing a context that no longer exists is not
    // an option; fall back to everything.
    final scope = ref.read(workspaceScopeProvider);
    if (scope.workspaceId == id) {
      ref.read(workspaceScopeProvider.notifier).select(WorkspaceScope.all);
    }
    _refresh();
    ref.read(projectsControllerProvider.notifier).refreshFromStore();
  }

  /// Files [projectId] under [workspaceId], or unassigns it when null. One
  /// `UPDATE`, not remove-then-add, so a project is never briefly homeless.
  void assign(String projectId, String? workspaceId) {
    ref.read(projectDaoProvider).setWorkspace(projectId, workspaceId);
    ref.read(projectsControllerProvider.notifier).refreshFromStore();
  }

  /// A trimmed description, or null — an empty string is the absence of one,
  /// never a description that happens to be blank.
  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void _rejectDuplicate(String name, {required String? exceptId}) {
    final lower = name.toLowerCase();
    for (final existing in state) {
      if (existing.id != exceptId && existing.name.toLowerCase() == lower) {
        throw DuplicateWorkspaceName(name);
      }
    }
  }

  void _refresh() => state = ref.read(workspaceDaoProvider).getAll();
}

final workspacesControllerProvider =
    NotifierProvider<WorkspacesController, List<Workspace>>(
      WorkspacesController.new,
    );

/// How many projects sit in each context, from the list already in memory —
/// one pass over `ProjectDao.getAll`, so no picker issues a `COUNT(*)`.
final workspaceProjectCountsProvider = Provider<Map<String, int>>((ref) {
  final counts = <String, int>{};
  for (final project in ref.watch(projectsControllerProvider)) {
    final id = project.workspaceId;
    if (id != null) counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
});

/// The second line a context gets in a picker: what it is for, or — when
/// nobody has said — how big it is.
String describeWorkspace(Workspace workspace, {required int projectCount}) =>
    workspace.description ??
    (projectCount == 1 ? '1 project' : '$projectCount projects');

/// Holds the scope the project list is narrowed to. In memory by design: a
/// filter that outlives its session is a project list mysteriously short.
class WorkspaceScopeController extends Notifier<WorkspaceScope> {
  @override
  WorkspaceScope build() => WorkspaceScope.all;

  void select(WorkspaceScope scope) => state = scope;
}

final workspaceScopeProvider =
    NotifierProvider<WorkspaceScopeController, WorkspaceScope>(
      WorkspaceScopeController.new,
    );

/// [sortedProjectsProvider] narrowed to the current scope — one pass over a
/// list already in memory. The selected project is never filtered away.
final workspaceScopedProjectsProvider = Provider<List<Project>>((ref) {
  final scope = ref.watch(workspaceScopeProvider);
  final projects = ref.watch(sortedProjectsProvider);
  if (scope.isAll) return projects;
  final selectedId = ref.watch(selectedProjectIdProvider);
  return [
    for (final project in projects)
      if (scope.includes(project) || project.id == selectedId) project,
  ];
});
