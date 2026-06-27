import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/project_import_service.dart';
import '../../environments/application/environment_providers.dart';
import '../../git/application/changes_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../domain/project.dart';
import 'project_providers.dart';
import 'project_service.dart';
import 'project_service_provider.dart';

/// Holds the list of persisted projects and drives project creation.
///
/// Reads are synchronous (SQLite), so the state is the plain project list; it is
/// refreshed explicitly after mutations.
class ProjectsController extends Notifier<List<Project>> {
  final Map<String, Future<ImportSummary>> _syncs = {};

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
    await _autoImportSessions(result.repositories);
    _refresh();
    return result;
  }

  /// Scans the CLI stores and imports any existing sessions for the new
  /// project's repositories (best-effort — never blocks project creation).
  Future<void> _autoImportSessions(List<Repository> repositories) async {
    try {
      final summary = await ref.read(autoImportRunnerProvider)(repositories);
      if (summary.sessions > 0) {
        ref.read(sessionsRevisionProvider.notifier).bump();
      }
    } catch (_) {
      // CLI stores unavailable — project creation still succeeds.
    }
  }

  /// Discovers CLI sessions created outside the app for an existing project.
  /// Concurrent requests for the same project share one filesystem scan.
  Future<ImportSummary> syncSessions(String projectId) {
    return _syncs.putIfAbsent(projectId, () async {
      ref.read(sessionSyncingProvider.notifier).start();
      try {
        final repos = ref.read(repositoryDaoProvider).getByProject(projectId);
        final summary = await ref.read(autoImportRunnerProvider)(repos);
        if (summary.sessions > 0) {
          ref.read(sessionsRevisionProvider.notifier).bump();
        }
        return summary;
      } finally {
        _syncs.remove(projectId);
        ref.read(sessionSyncingProvider.notifier).finish();
      }
    });
  }

  /// Creates a project for [targetEnvironmentId] from a Windows-host folder
  /// [windowsPath] (a drive or `\\wsl.localhost\…` path the picker returned),
  /// binding the project and its repositories to the chosen environment.
  Future<ProjectCreationResult> createInEnvironment({
    required String name,
    required String windowsPath,
    required String targetEnvironmentId,
  }) async {
    final dao = ref.read(executionEnvironmentDaoProvider);
    final windows = dao.getById(localWindowsEnvironmentId);
    final target = dao.getById(targetEnvironmentId) ?? windows;
    if (windows == null || target == null) {
      throw StateError('No execution environments available.');
    }
    final result = await ref
        .read(projectServiceProvider)
        .createProjectForEnvironment(
          name: name,
          windowsScanPath: windowsPath,
          windows: windows,
          target: target,
        );
    await _autoImportSessions(result.repositories);
    _refresh();
    return result;
  }

  /// Removes [projectId] from the workspace. The database cascades to its
  /// repositories, sessions, events and imported sessions. Clears any selection
  /// that pointed into the deleted project.
  void deleteProject(String projectId) {
    final repoIds = ref
        .read(repositoryDaoProvider)
        .getByProject(projectId)
        .map((r) => r.id)
        .toSet();
    ref.read(projectDaoProvider).delete(projectId);
    if (ref.read(selectedProjectIdProvider) == projectId) {
      ref.read(selectedProjectIdProvider.notifier).select(null);
    }
    final selectedRepo = ref.read(selectedRepositoryIdProvider);
    if (selectedRepo != null && repoIds.contains(selectedRepo)) {
      ref.read(selectedRepositoryIdProvider.notifier).select(null);
    }
    ref.read(sessionsRevisionProvider.notifier).bump();
    _refresh();
  }

  void _refresh() => state = ref.read(projectDaoProvider).getAll();
}

final projectsControllerProvider =
    NotifierProvider<ProjectsController, List<Project>>(ProjectsController.new);

/// Holds the currently selected project id, or `null` when none is selected.
class SelectedProjectController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) {
    state = id;
    if (id != null) {
      // Selection should remain immediate; discovery completes in the
      // background and bumps the session list when new CLI sessions are found.
      unawaited(
        ref
            .read(projectsControllerProvider.notifier)
            .syncSessions(id)
            .catchError((_) => const ImportSummary()),
      );
    }
  }
}

class SessionSyncingController extends Notifier<int> {
  @override
  int build() => 0;
  void start() => state++;
  void finish() => state = state > 0 ? state - 1 : 0;
}

/// Number of active CLI-store scans. Exposed so the Explorer can make
/// background synchronization visible without blocking project navigation.
final sessionSyncingProvider = NotifierProvider<SessionSyncingController, int>(
  SessionSyncingController.new,
);

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
