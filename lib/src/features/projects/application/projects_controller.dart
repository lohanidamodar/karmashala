import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/process/command_runner_providers.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/project_import_service.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/execution_environment.dart';
import '../../git/application/changes_providers.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/local_environment.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_actions.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
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

  /// Rebuilds the workspace project list entirely from Claude/Codex stores.
  /// Detection completes before any destructive change, so a scan failure
  /// leaves the current workspace untouched.
  Future<ImportSummary> clearAndReimportFromCli() async {
    final detectedController = ref.read(
      detectedProjectsControllerProvider.notifier,
    );
    await detectedController.detect();
    final detectedState = ref.read(detectedProjectsControllerProvider);
    if (detectedState.hasError) {
      throw StateError('CLI session detection failed: ${detectedState.error}');
    }
    final detected = detectedState.asData?.value ?? const [];

    for (final project in ref.read(projectDaoProvider).getAll()) {
      ref.read(projectDaoProvider).delete(project.id);
    }
    ref.read(selectedProjectIdProvider.notifier).select(null);
    ref.read(selectedRepositoryIdProvider.notifier).select(null);
    ref.read(selectedSessionIdProvider.notifier).select(null);
    ref.read(selectedImportedSessionIdProvider.notifier).select(null);

    final summary = ref.read(projectImportServiceProvider).importAll(detected);
    ref.read(sessionsRevisionProvider.notifier).bump();
    _refresh();
    return summary;
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

  /// Re-runs repository discovery over [projectId]'s root and records anything
  /// new. Returns the repositories that were added.
  ///
  /// [ProjectService.rediscover] has existed since the discovery work and had
  /// never had a caller: a project scanned once kept whatever it found then, so
  /// a repository cloned into it afterwards stayed invisible. The Explorer's
  /// tree now depends on this being reachable — a session working in a folder
  /// with no `repositories` row is drawn as "not scanned yet", and this is the
  /// action that turns such a row into a real one.
  Future<List<Repository>> rediscover(String projectId) async {
    final project = ref.read(projectDaoProvider).getById(projectId);
    if (project == null) {
      throw StateError('This project is no longer in the workspace.');
    }
    final added = await ref.read(projectServiceProvider).rediscover(project);
    if (added.isNotEmpty) {
      // New repositories may already have CLI history behind them, and the
      // tree's providers all hang off the revision.
      await _autoImportSessions(added);
      ref.read(sessionsRevisionProvider.notifier).bump();
    }
    _refresh();
    return added;
  }

  /// Removes [projectId] from the workspace. The database cascades to its
  /// repositories, sessions, events and imported sessions. Clears any selection
  /// that pointed into the deleted project.
  ///
  /// When [deleteCliSessions] is set, each of the project's imported CLI
  /// sessions is also deleted from the originating agent's on-disk store
  /// (Claude/Codex history), best-effort, before the workspace rows are removed.
  Future<void> deleteProject(
    String projectId, {
    bool deleteCliSessions = false,
  }) async {
    final repos = ref.read(repositoryDaoProvider).getByProject(projectId);
    if (deleteCliSessions) {
      final actions = ref.read(sessionActionsProvider);
      final importedDao = ref.read(importedSessionDaoProvider);
      for (final repo in repos) {
        for (final session in importedDao.getByRepository(repo.id)) {
          try {
            await actions.deleteImported(session, deleteFromCli: true);
          } catch (_) {
            // Best-effort per session — a locked/removed file shouldn't block
            // deleting the rest or the project itself.
          }
        }
      }
    }
    final repoIds = repos.map((r) => r.id).toSet();
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

/// Whether a project's root folder no longer exists on disk. Resolves the
/// Windows-reachable path (a `\\wsl.localhost\…` UNC form for WSL projects) and
/// checks it. Defaults to "not missing" while loading or if it can't be
/// resolved, so the UI never falsely flags a project.
final projectPathMissingProvider = FutureProvider.autoDispose
    .family<bool, Project>((ref, project) async {
      final environmentDao = ref.read(executionEnvironmentDaoProvider);
      final env = environmentDao.getById(project.environmentId);
      if (env == null) return false;

      var path = project.root.path;
      if (env.kind == EnvironmentKind.wsl) {
        ExecutionEnvironment? windows;
        for (final e in environmentDao.getAll()) {
          if (e.kind == EnvironmentKind.windowsNative) {
            windows = e;
            break;
          }
        }
        if (windows == null) return false;
        try {
          path = ref
              .read(pathTranslatorProvider)
              .translate(project.root, from: env, to: windows)
              .path;
        } catch (_) {
          return false;
        }
      }
      try {
        return !await Directory(path).exists();
      } catch (_) {
        return false;
      }
    });

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

/// Projects ordered with pinned ones first (preserving their relative order),
/// then the rest. Read by the Explorer's tree and by Quick Open's project and
/// file sources — the mini launcher it also named was removed in Loop 59.
final sortedProjectsProvider = Provider<List<Project>>((ref) {
  final projects = ref.watch(projectsControllerProvider);
  final pinned = ref
      .watch(settingsControllerProvider.select((s) => s.pinnedProjectIds))
      .toSet();
  if (pinned.isEmpty) return projects;
  final top = <Project>[];
  final rest = <Project>[];
  for (final project in projects) {
    (pinned.contains(project.id) ? top : rest).add(project);
  }
  return [...top, ...rest];
});

/// Repositories belonging to the currently selected project. Recomputes when the
/// selection or the project list changes.
final selectedProjectRepositoriesProvider = Provider<List<Repository>>((ref) {
  final id = ref.watch(selectedProjectIdProvider);
  ref.watch(projectsControllerProvider);
  if (id == null) return const [];
  return ref.read(repositoryDaoProvider).getByProject(id);
});
