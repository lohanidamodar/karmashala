import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/project_import_service.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/project.dart';
import 'cli_store_purge.dart';
import 'project_providers.dart';
import 'project_service.dart';
import 'project_service_provider.dart';

/// Holds the list of persisted projects and drives project creation.
///
/// Reads are synchronous (SQLite), so the state is the plain project list; it is
/// refreshed explicitly after mutations.
class ProjectsController extends Notifier<List<Project>> {
  final Map<String, Future<ImportSummary>> _syncs = {};

  /// The once-per-lifecycle import, held so a second caller joins it rather
  /// than starting a second walk of every store.
  Future<ImportSummary>? _lifecycleImport;

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
      environmentId: localHostEnvironmentId,
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

  /// The **one** CLI-store import of this app's life, run after the first
  /// frame (`AppLifecycle.importCliSessions`).
  ///
  /// It used to run on every project expand *and* every project selection, and
  /// each run was a full walk of every store — so a workspace of five projects
  /// paid five concurrent walks of the owner's 663-file Claude store across
  /// `\\wsl.localhost`, with the Explorer's spinner up for all of it. That is
  /// the "what is it loading on every expand?" the owner profiled.
  ///
  /// Every repository in the workspace, in one pass, because the walk is per
  /// *store* and not per project: doing it project by project would read the
  /// same store once per project. What is left for the user is the per-project
  /// **Refresh CLI sessions**, which is the same import narrowed to one
  /// project's repositories.
  Future<ImportSummary> importCliSessionsOnce() {
    return _lifecycleImport ??= _import(
      () => ref.read(repositoryDaoProvider).getAll(),
      onDone: () => ref.read(cliSessionsCheckedProvider.notifier).stampAll(),
    );
  }

  /// Discovers CLI sessions created outside the app for an existing project.
  /// Concurrent requests for the same project share one filesystem scan.
  Future<ImportSummary> syncSessions(String projectId) {
    return _syncs.putIfAbsent(projectId, () async {
      try {
        return await _import(
          () => ref.read(repositoryDaoProvider).getByProject(projectId),
          onDone: () => ref
              .read(cliSessionsCheckedProvider.notifier)
              .stampProject(projectId),
        );
      } finally {
        _syncs.remove(projectId);
      }
    });
  }

  /// One import, with the spinner held for exactly its duration and the
  /// freshness stamped only once it really finished.
  Future<ImportSummary> _import(
    List<Repository> Function() repositories, {
    required void Function() onDone,
  }) async {
    ref.read(sessionSyncingProvider.notifier).start();
    try {
      final summary = await ref.read(autoImportRunnerProvider)(repositories());
      if (summary.sessions > 0) {
        ref.read(sessionsRevisionProvider.notifier).bump();
      }
      onDone();
      return summary;
    } finally {
      ref.read(sessionSyncingProvider.notifier).finish();
    }
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
    // Every store was read and everything in them imported, so this reading
    // does speak for the whole workspace.
    ref.read(cliSessionsCheckedProvider.notifier).stampAll();
    ref.read(sessionsRevisionProvider.notifier).bump();
    _refresh();
    return summary;
  }

  /// Creates a project for [targetEnvironmentId] from a Windows-host folder
  /// [windowsPath] (a drive or `\\wsl.localhost\…` path the picker returned),
  /// binding the project and its repositories to the chosen environment.
  ///
  /// [workspaceId] is whatever the dialog was showing when the user pressed
  /// create — a suggestion they left alone, one they changed, or nothing. It is
  /// written once, here, and no existing project is touched.
  Future<ProjectCreationResult> createInEnvironment({
    required String name,
    required String windowsPath,
    required String targetEnvironmentId,
    String? workspaceId,
  }) async {
    final dao = ref.read(executionEnvironmentDaoProvider);
    final windows = dao.getById(localHostEnvironmentId);
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
          workspaceId: workspaceId,
        );
    await _autoImportSessions(result.repositories);
    _refresh();
    return result;
  }

  /// Creates a project on [targetEnvironmentId], optionally cloning [gitRepoUrl].
  ///
  /// Works across local Windows, WSL, and remote SSH environments.
  Future<ProjectCreationResult> createProject({
    required String name,
    required String targetEnvironmentId,
    required String folderPath,
    String? gitRepoUrl,
    String? workspaceId,
  }) async {
    final target = ref
        .read(environmentResolverProvider)
        .resolve(targetEnvironmentId)
        .require;
    final result = await ref.read(projectServiceProvider).createProject(
          name: name,
          target: target,
          targetPath: folderPath,
          gitRepoUrl: gitRepoUrl,
          workspaceId: workspaceId,
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
    // The same pair `createInEnvironment` resolves, and for the same reason:
    // the scan runs on the Windows host, the rows belong to the project's own
    // environment.
    final dao = ref.read(executionEnvironmentDaoProvider);
    final windows = dao.getById(localHostEnvironmentId);
    final environment = dao.getById(project.root.environmentId) ?? windows;
    if (windows == null || environment == null) {
      throw StateError('No execution environments available.');
    }
    final added = await ref
        .read(projectServiceProvider)
        .rediscover(
          project,
          projectEnvironment: environment,
          windows: windows,
        );
    // A rescan is also the moment to notice what has *gone*. It only ever
    // added, so a worktree deleted from the command line stayed in the table
    // for ever — offered in every picker, stat'd by every cost the tree pays.
    //
    // **Not awaited**, and that is the point: the caller asked what the scan
    // *found*, and retirement answers a different question by probing the
    // filesystem once per checkout — which over a stopped distribution's UNC
    // blocks for seconds each. Making the rescan wait on it would stall the
    // very screen the user is watching for a fact nobody asked for. It bumps
    // the revision itself when it changes something.
    unawaited(_retireMissingCheckouts(projectId, project, environment, windows));
    if (added.isNotEmpty) {
      // New repositories may already have CLI history behind them, and the
      // tree's providers all hang off the revision.
      await _autoImportSessions(added);
      ref.read(sessionsRevisionProvider.notifier).bump();
    }
    _refresh();
    return added;
  }

  /// Drops the rows whose directories are provably gone, and says nothing when
  /// it cannot tell. The service refuses to retire anything unless the project
  /// root itself answered present, so a stopped distro or an unmounted drive
  /// cannot delete a workspace.
  Future<void> _retireMissingCheckouts(
    String projectId,
    Project project,
    ExecutionEnvironment environment,
    ExecutionEnvironment windows,
  ) async {
    try {
      final report = await ref
          .read(checkoutRetirementServiceProvider)
          .retireMissingCheckouts(
            projectId: projectId,
            root: project.root,
            environment: environment,
            windows: windows,
          );
      if (report.retired.isEmpty) return;
      ref.read(sessionsRevisionProvider.notifier).bump();
      _refresh();
    } catch (error) {
      // A tidy-up that fails is not a failed rescan. The rows it would have
      // dropped are still there, which is the safe direction.
      AppLogger.named('projects').warning(
        'Retiring missing checkouts failed: $error',
      );
    }
  }

  /// Removes [projectId] from the workspace. The database cascades to its
  /// repositories, sessions, events and imported sessions. Clears any selection
  /// that pointed into the deleted project.
  ///
  /// When [deleteCliSessions] is set, the project's imported CLI sessions are
  /// also deleted from the originating agents' on-disk stores (Claude/Codex
  /// history) — **after** this returns, by [CliStorePurgeRunner], which reports
  /// anything it could not remove.
  ///
  /// The workspace half is synchronous and the store half is not, and the split
  /// is the point. This used to delete the store files inline, one session at a
  /// time: a store-index pass, a `DELETE` and a signal fan-out **each**, all on
  /// the UI isolate, so a project of 33 sessions decoded 289 index records,
  /// rewrote the Codex index 33 times and woke every watcher of the session list
  /// 34 times before the row disappeared. Now the row goes at once, the store is
  /// purged in one pass per store behind it, and the whole thing publishes once.
  /// See `project_delete_cost_test.dart`.
  Future<void> deleteProject(
    String projectId, {
    bool deleteCliSessions = false,
  }) async {
    final project = ref.read(projectDaoProvider).getById(projectId);
    final repos = ref.read(repositoryDaoProvider).getByProject(projectId);
    final repoIds = repos.map((r) => r.id).toSet();
    // Read before the rows go: the cascade takes the records with the project,
    // and the store still has to be told which files they named.
    final imported = deleteCliSessions
        ? [
            for (final repo in repos)
              ...ref.read(importedSessionDaoProvider).getByRepository(repo.id),
          ]
        : const <ImportedSession>[];

    // Resolved before the delete: the cascade takes the session rows with the
    // project, so afterwards there is nothing left to ask which repository a
    // selected session belonged to.
    final selection = _selectionInto(repoIds);

    ref.read(projectDaoProvider).delete(projectId);
    _clearSelections(projectId, repoIds, selection);
    // One publish for the whole delete. It used to be one per session plus this
    // one, and each of those woke every watcher of the session list.
    ref.read(sessionsRevisionProvider.notifier).bump();
    _refresh();

    ref
        .read(cliStorePurgeRunnerProvider)
        .start(projectName: project?.name ?? 'The project', sessions: imported);
  }

  /// Whether the selected session — native, imported — sits in [repoIds].
  ///
  /// Asked *before* the project row goes, because the cascade takes the answer
  /// with it.
  ({bool session, bool imported}) _selectionInto(Set<String> repoIds) {
    final session = ref.read(selectedSessionIdProvider);
    final imported = ref.read(selectedImportedSessionIdProvider);
    return (
      session: session != null &&
          repoIds.contains(
            ref.read(sessionDaoProvider).getById(session)?.repositoryId,
          ),
      imported: imported != null &&
          repoIds.contains(
            ref.read(importedSessionDaoProvider).getById(imported)?.repositoryId,
          ),
    );
  }

  /// Drops any selection that pointed into the project just deleted.
  ///
  /// The two session halves are new here only in *where* they happen: they used
  /// to ride along inside the per-session delete, which meant they ran only when
  /// "delete session files" was ticked — so removing a project without it left
  /// the app selecting a session whose row the cascade had taken.
  void _clearSelections(
    String projectId,
    Set<String> repoIds,
    ({bool session, bool imported}) selection,
  ) {
    if (ref.read(selectedProjectIdProvider) == projectId) {
      ref.read(selectedProjectIdProvider.notifier).select(null);
    }
    final selectedRepo = ref.read(selectedRepositoryIdProvider);
    if (selectedRepo != null && repoIds.contains(selectedRepo)) {
      ref.read(selectedRepositoryIdProvider.notifier).select(null);
    }
    if (selection.session) {
      ref.read(selectedSessionIdProvider.notifier).select(null);
    }
    if (selection.imported) {
      ref.read(selectedImportedSessionIdProvider.notifier).select(null);
    }
  }

  /// Re-reads the project rows. Public because the one mutation that does not
  /// go through this controller — filing a project under a workspace — still
  /// has to reach everything watching the list.
  void refreshFromStore() => _refresh();

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
      if (env.kind == EnvironmentKind.ssh) return false;

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

  /// Selecting a project scans nothing.
  ///
  /// It used to start a full CLI-store import — so every click in the Explorer,
  /// and every expand (which selects too), walked every store again. The import
  /// runs once after the first frame now, and on demand from the project row's
  /// **Refresh CLI sessions**.
  void select(String? id) => state = id;
}

/// When the CLI stores were last read, and for which project.
///
/// §19's rule, applied to a list that can now be out of date: a reading is
/// shown with its age, and *no* reading says so rather than saying nothing.
/// Before the first-frame import lands, [all] is null and the Explorer says the
/// stores have not been checked instead of implying the tree is current.
class CliSessionsChecked {
  const CliSessionsChecked({this.all, this.byProject = const {}});

  /// When every store was last read for every repository in the workspace.
  final DateTime? all;

  /// When one project was last refreshed on its own. A per-project refresh
  /// reads the stores but only imports for that project, so it may not speak
  /// for any other.
  final Map<String, DateTime> byProject;

  /// The freshest reading that covers [projectId], or null for none.
  DateTime? forProject(String projectId) {
    final mine = byProject[projectId];
    final everything = all;
    if (mine == null) return everything;
    if (everything == null) return mine;
    return mine.isAfter(everything) ? mine : everything;
  }
}

class CliSessionsCheckedController extends Notifier<CliSessionsChecked> {
  @override
  CliSessionsChecked build() => const CliSessionsChecked();

  void stampAll() => state = CliSessionsChecked(
    all: ref.read(clockProvider).nowUtc(),
    byProject: state.byProject,
  );

  void stampProject(String projectId) => state = CliSessionsChecked(
    all: state.all,
    byProject: {...state.byProject, projectId: ref.read(clockProvider).nowUtc()},
  );
}

/// When the CLI stores were last read. Watched by the Explorer so the tree
/// never implies a freshness nobody measured.
final cliSessionsCheckedProvider =
    NotifierProvider<CliSessionsCheckedController, CliSessionsChecked>(
      CliSessionsCheckedController.new,
    );

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
