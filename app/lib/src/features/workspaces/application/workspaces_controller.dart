import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_projects/karmashala_projects.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/id_generator_provider.dart';
import '../../projects/application/projects_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../data/workspace_data.dart';
import '../domain/workspace_scope.dart';

/// The user's contexts, and the four verbs over them: create, rename, delete,
/// assign. The list follows the server's copy, whoever changed it; every
/// write is the server's to validate, and a refusal ([DataRefused]) says why
/// in words fit to show.
class WorkspacesController extends Notifier<List<Workspace>> {
  WorkspaceData get _data => ref.read(workspaceDataProvider);

  @override
  List<Workspace> build() {
    final data = ref.watch(workspaceDataProvider);
    final workspaces = data.workspaces;
    final listening = data.workspaceChanges.listen(
      (_) => state = data.workspaces,
    );
    ref.onDispose(listening.cancel);
    return workspaces;
  }

  Future<Workspace> create(String name, {String? description}) => _data.write(
    WorkspacePut(
      id: ref.read(idGeneratorProvider).newId(),
      workspaceName: name,
      description: description,
    ),
  );

  /// The name and the description together, because they are edited together.
  /// A blank description **clears** it — a form that can only add cannot correct.
  Future<Workspace> edit(
    String id, {
    required String name,
    String? description,
  }) => _data.write(
    WorkspacePut(id: id, workspaceName: name, description: description),
  );

  /// The name alone, leaving whatever description the context already had.
  Future<Workspace> rename(String id, String name) => edit(
    id,
    name: name,
    description: state.where((w) => w.id == id).firstOrNull?.description,
  );

  /// The colour's name, or null for none. Stored as the word, so a colour a
  /// newer build named is kept through an older one rather than erased.
  Future<Workspace> setColor(String id, String? color) =>
      _data.write(WorkspaceSetColor(id: id, color: color));

  /// Deletes the context. **Its projects are kept**, unassigned.
  Future<void> delete(String id) async {
    // Whatever was being shown, showing a context that no longer exists is not
    // an option; fall back to everything.
    final scope = ref.read(workspaceScopeProvider);
    if (scope.workspaceId == id) {
      ref.read(workspaceScopeProvider.notifier).select(WorkspaceScope.all);
    }
    await _data.write(WorkspaceDelete(id));
  }

  /// Files [projectId] under [workspaceId], or unassigns it when null — one
  /// write, so a project is never briefly homeless.
  Future<void> assign(String projectId, String? workspaceId) =>
      assignAll({projectId: workspaceId});

  /// Files many projects at once — [placements] maps a project id to its
  /// context, or null to unassign — in one transaction.
  Future<void> assignAll(Map<String, String?> placements) async {
    if (placements.isEmpty) return;
    await _data.write(ProjectsFile(placements));
  }
}

final workspacesControllerProvider =
    NotifierProvider<WorkspacesController, List<Workspace>>(
      WorkspacesController.new,
    );

/// How many projects sit in each context, from the list already in memory.
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

/// Holds the scope the project list is narrowed to. Kept across launches now
/// that the Explorer's chips say which one is in force: a filter nobody can
/// see was a project list mysteriously short, and this one can be seen.
class WorkspaceScopeController extends Notifier<WorkspaceScope> {
  @override
  WorkspaceScope build() {
    // Read, not watched: the scope is written from here and nowhere else.
    final scope = WorkspaceScope.parse(
      ref.read(settingsControllerProvider).explorerContextScope,
    );
    final id = scope.workspaceId;
    // A context deleted since the scope was stored shows everything.
    if (id != null &&
        !ref.read(workspacesControllerProvider).any((w) => w.id == id)) {
      return WorkspaceScope.all;
    }
    return scope;
  }

  void select(WorkspaceScope scope) {
    state = scope;
    ref
        .read(settingsControllerProvider.notifier)
        .setExplorerContextScope(scope.stored);
  }
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
