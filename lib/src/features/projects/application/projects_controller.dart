import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../domain/project.dart';
import 'project_providers.dart';
import 'project_service.dart';
import 'project_service_provider.dart';

/// Holds the list of persisted projects and drives project creation.
///
/// Reads are synchronous (SQLite), so the state is the plain project list; it is
/// refreshed explicitly after mutations.
class ProjectsController extends Notifier<List<Project>> {
  @override
  List<Project> build() => ref.watch(projectDaoProvider).getAll();

  /// Creates a project at a local Windows folder [path] named [name], discovers
  /// repositories under it, and refreshes the list. Returns the result so the UI
  /// can report how many repositories were found.
  Future<ProjectCreationResult> createByDiscovery({
    required String name,
    required String path,
  }) async {
    final root = EnvironmentPath(
      environmentId: localWindowsEnvironmentId,
      path: path,
    );
    final result = await ref
        .read(projectServiceProvider)
        .createProjectByDiscovery(name: name, root: root);
    _refresh();
    return result;
  }

  void _refresh() => state = ref.read(projectDaoProvider).getAll();
}

final projectsControllerProvider =
    NotifierProvider<ProjectsController, List<Project>>(ProjectsController.new);

/// Holds the currently selected project id, or `null` when none is selected.
class SelectedProjectController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

/// The currently selected project id, or `null` when none is selected.
final selectedProjectIdProvider =
    NotifierProvider<SelectedProjectController, String?>(
      SelectedProjectController.new,
    );

/// Repositories belonging to the currently selected project. Recomputes when the
/// selection or the project list changes.
final selectedProjectRepositoriesProvider = Provider<List<Repository>>((ref) {
  final id = ref.watch(selectedProjectIdProvider);
  ref.watch(projectsControllerProvider);
  if (id == null) return const [];
  return ref.read(repositoryDaoProvider).getByProject(id);
});
