import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  ///
  /// A blank description **clears** it: emptying the field is how you say the
  /// sentence no longer applies, and a form that can only ever add text is a
  /// form you cannot correct.
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

  /// Deletes the context. **Its projects are kept** and become unassigned —
  /// the schema's `ON DELETE SET NULL` does that. Losing four buckets must
  /// never mean losing 31 projects, so this refreshes the project list rather
  /// than deleting anything from it.
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

  /// Files [projectId] under [workspaceId], or unassigns it when null.
  ///
  /// **Moving between contexts is this, once.** There is no remove-then-add:
  /// one `UPDATE` replaces whatever the project was filed under, so the two
  /// halves cannot be interrupted between and a project is never briefly
  /// homeless. Unassigning is the same call with null — the project itself is
  /// never touched, which is the whole difference between losing a grouping
  /// and losing a project.
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

/// How many projects sit in each context, from the list already in memory.
///
/// Every picker of contexts wants a second line, and a context with no
/// description has to say *something*: how many projects are in it is the one
/// fact that is free. One pass over `ProjectDao.getAll`'s own rows — the same
/// list `workspaceScopedProjectsProvider` narrows — so no picker anywhere in
/// the app issues a `COUNT(*)`, let alone one per context per row.
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

/// Holds the scope the project list is narrowed to. In memory by design: it is
/// a view of the moment, not a preference, and a filter that outlives the
/// session it was set in is a project list that is mysteriously short at
/// breakfast.
class WorkspaceScopeController extends Notifier<WorkspaceScope> {
  @override
  WorkspaceScope build() => WorkspaceScope.all;

  void select(WorkspaceScope scope) => state = scope;
}

final workspaceScopeProvider =
    NotifierProvider<WorkspaceScopeController, WorkspaceScope>(
      WorkspaceScopeController.new,
    );

/// The project list the Explorer draws: [sortedProjectsProvider] narrowed to
/// the current [workspaceScopeProvider].
///
/// **No query per project, and no query at all.** `workspace_id` arrives on the
/// row `ProjectDao.getAll` already reads, so narrowing is one pass over a list
/// that is in memory anyway — switching contexts issues zero statements. See
/// `workspace_filter_cost_test.dart`.
///
/// **The selected project is never filtered away.** Filtering is a view, not a
/// navigation action: the selection drives the session list, the chat and the
/// terminal, so dropping it because the user glanced at another context would
/// throw away the thing they were in the middle of. Keeping the selection but
/// hiding its row is the other half of the same mistake — the session pane
/// would then show work whose project is nowhere on screen. So the selection
/// stays *and* stays visible, in its usual place in the list.
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
