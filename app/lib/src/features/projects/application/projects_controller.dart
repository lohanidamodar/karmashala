import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';
import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/util/clock_provider.dart';
import '../../cli_detection/application/cli_detection_providers.dart';
import '../../cli_detection/application/project_import_service.dart';
import 'package:agent_cli/read.dart';
import '../../environments/application/environment_providers.dart';
import '../../environments/application/environment_resolver.dart';
import '../../explorer/application/project_head.dart';
import 'package:agent_cli/process.dart';
import '../../git/application/changes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import 'package:karmashala_git/repositories.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/project.dart';
import 'cli_store_purge.dart';
import 'project_providers.dart';
import 'project_service.dart';
import 'project_service_provider.dart';
import 'wsl_path_existence.dart';

/// Holds the list of persisted projects and drives project creation. Reads are
/// synchronous, so the state is the plain list, refreshed after mutations.
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

  /// The **one** CLI-store import of this app's life, run after the first frame.
  /// One pass over every store, because the walk is per store, not per project.
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
        unawaited(_syncs.remove(projectId));
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
    _refileNotesAndTodos();
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

  /// Creates a project for [targetEnvironmentId] from a Windows-host folder,
  /// binding it and its repositories to that environment.
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
    final result = await ref
        .read(projectServiceProvider)
        .createProject(
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

  /// Edits [projectId]: its name, where its root folder is, and which checkout
  /// its one-click session runs in. A moved root fails before anything is
  /// written when the new folder cannot be read.
  Future<ProjectUpdateResult> updateProject(
    String projectId, {
    String? name,
    String? folderPath,
    String? targetEnvironmentId,
    String? defaultRepositoryId,
    bool clearDefaultRepository = false,
  }) async {
    final project = ref.read(projectDaoProvider).getById(projectId);
    if (project == null) {
      throw StateError('This project is no longer in the workspace.');
    }

    final dao = ref.read(executionEnvironmentDaoProvider);
    final windows = dao.getById(localHostEnvironmentId);
    final environmentId = targetEnvironmentId ?? project.root.environmentId;
    final target = dao.getById(environmentId) ?? windows;
    if (windows == null || target == null) {
      throw StateError('No execution environments available.');
    }

    final trimmed = folderPath?.trim();
    final root = trimmed == null || trimmed.isEmpty
        ? (targetEnvironmentId == null
              ? null
              : EnvironmentPath(
                  environmentId: environmentId,
                  path: project.root.path,
                ))
        : EnvironmentPath(environmentId: environmentId, path: trimmed);

    final result = await ref
        .read(projectServiceProvider)
        .updateProject(
          project,
          name: name,
          root: root,
          defaultRepositoryId: defaultRepositoryId,
          clearDefaultRepository: clearDefaultRepository,
          target: target,
          windows: windows,
        );
    if (result.discovered.isNotEmpty) {
      await _autoImportSessions(result.discovered);
    }
    // Every checkout row a session points at may have moved, so the tree has to
    // redraw even when nothing was discovered.
    if (result.rebased.isNotEmpty || result.discovered.isNotEmpty) {
      ref.read(sessionsRevisionProvider.notifier).bump();
    }
    _refresh();
    return result;
  }

  /// Where a session started at [projectId] runs, recording the project's own
  /// folder when the workspace has no checkout for it at all.
  ///
  /// Git is not what makes a directory runnable — every agent CLI starts in a
  /// plain one — so a project with nothing discovered under it still has
  /// somewhere to run: itself. Creation and [rediscover] already say that; this
  /// is the same sentence said at the moment a session is asked for, which is
  /// what a project recorded before it was true never got.
  ///
  /// Throws, in words, for the two things that really do stop a start: the
  /// project is gone, or its folder is.
  Repository ensureRunLocation(String projectId) {
    final project = ref.read(projectDaoProvider).getById(projectId);
    if (project == null) {
      throw StateError('This project is no longer in the workspace.');
    }
    final recorded = ref.read(repositoryDaoProvider).getByProject(projectId);
    if (recorded.isNotEmpty) return recorded.first;
    if (_rootProvablyMissing(project)) {
      throw StateError(
        '"${project.name}" has no folder at ${project.root.path}. Point the '
        'project at where it lives — Edit project — or add it again.',
      );
    }
    final checkout = ref
        .read(projectServiceProvider)
        .recordRootAsCheckout(project);
    ref.read(sessionsRevisionProvider.notifier).bump();
    _refresh();
    return checkout;
  }

  /// Whether [project]'s root is **provably** not there, from one `stat` this
  /// process can make cheaply. A WSL or SSH root is never called missing from
  /// here: [projectPathMissingProvider] is the asynchronous form that can ask
  /// those properly, and "we did not look" must not read as "it is gone".
  bool _rootProvablyMissing(Project project) {
    final env = ref
        .read(executionEnvironmentDaoProvider)
        .getById(project.environmentId);
    if (env == null) return false;
    if (env.kind != EnvironmentKind.windowsNative &&
        env.kind != EnvironmentKind.localPosix) {
      return false;
    }
    final path = project.root.path;
    // A share, whoever it is filed under — the same exclusion the async probe
    // makes, and for the same reason (docs/windows-antivirus.md).
    if (path.startsWith(r'\\') || path.startsWith('//')) return false;
    try {
      return !Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Points [projectId]'s one-click "New session" at [repositoryId], or back at
  /// the picker's first row when null.
  void setDefaultRepository(String projectId, String? repositoryId) {
    ref.read(projectDaoProvider).setDefaultRepository(projectId, repositoryId);
    _refresh();
  }

  /// Re-runs repository discovery over [projectId]'s root and records anything
  /// new. Without it a repository cloned in after the first scan stays invisible.
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
        .rediscover(project, projectEnvironment: environment, windows: windows);
    // Asked for: the folder's own answer is taken again, not from what is kept.
    if (environment.wslDistribution case final distribution?) {
      ref
          .read(wslPathExistenceProvider)
          .forget(distribution, project.root.path);
    }
    ref.invalidate(projectPathMissingProvider(project));
    // A rescan is also the moment to notice what has gone. **Not awaited**: it
    // probes once per checkout, which over a stopped distro's UNC blocks for
    // seconds each, and the caller asked what the scan *found*.
    unawaited(
      _retireMissingCheckouts(projectId, project, environment, windows),
    );
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
  /// it cannot tell — the project root itself must have answered present.
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
      AppLogger.named(
        'projects',
      ).warning('Retiring missing checkouts failed: $error');
    }
  }

  /// Removes [projectId]; the database cascades. With [deleteCliSessions] the
  /// agents' own store files go too, *after* this returns, in one pass per store.
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
    _refileNotesAndTodos();
    _clearSelections(projectId, repoIds, selection);
    // One publish for the whole delete. It used to be one per session plus this
    // one, and each of those woke every watcher of the session list.
    ref.read(sessionsRevisionProvider.notifier).bump();
    _refresh();

    ref
        .read(cliStorePurgeRunnerProvider)
        .start(projectName: project?.name ?? 'The project', sessions: imported);
  }

  /// A project deleted here, not through the server, unfiles its notes and
  /// todos in the store (`ON DELETE SET NULL`): the server's copies are read
  /// again. Goes when projects move to the data API.
  void _refileNotesAndTodos() {
    final data = ref.read(dataClientProvider);
    for (final domain in [DataDomain.notes, DataDomain.todos]) {
      unawaited(data.resync(domain).catchError((Object _) {}));
    }
  }

  /// Whether the selected session sits in [repoIds]. Asked *before* the project
  /// row goes, because the cascade takes the answer with it.
  ({bool session, bool imported}) _selectionInto(Set<String> repoIds) {
    final session = ref.read(selectedSessionIdProvider);
    final imported = ref.read(selectedImportedSessionIdProvider);
    return (
      session:
          session != null &&
          repoIds.contains(
            ref.read(sessionDaoProvider).getById(session)?.repositoryId,
          ),
      imported:
          imported != null &&
          repoIds.contains(
            ref
                .read(importedSessionDaoProvider)
                .getById(imported)
                ?.repositoryId,
          ),
    );
  }

  /// Drops any selection that pointed into the project just deleted. These used
  /// to ride inside the per-session delete, so they ran only when files went too.
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

/// Whether a project's root folder no longer exists. Defaults to "not
/// missing" while loading, unresolvable or **not checked**, so the UI never
/// falsely flags one.
///
/// An SSH project is never asked. A WSL project is asked from inside its
/// distribution ([WslPathExistence]) — batched, kept, asked again when the
/// window comes back to the front or the project is rescanned, and never by a
/// stat over `\\wsl.localhost` (docs/windows-antivirus.md).
final projectPathMissingProvider = FutureProvider.autoDispose
    .family<bool, Project>((ref, project) async {
      final environmentDao = ref.read(executionEnvironmentDaoProvider);
      final env = environmentDao.getById(project.environmentId);
      if (env == null) return false;
      if (env.kind == EnvironmentKind.ssh) return false;

      final path = project.root.path;
      if (env.kind == EnvironmentKind.wsl) {
        final distribution = env.wslDistribution;
        // Swept once for the whole workspace, not once per WSL project.
        final windows = ref.watch(localEnvironmentProvider);
        if (distribution == null ||
            windows?.kind != EnvironmentKind.windowsNative) {
          return false;
        }
        final exists = await ref
            .read(wslPathExistenceProvider)
            .exists(
              distribution,
              path,
              stamp: ref.watch(windowRefocusCountProvider),
            );
        return exists == false;
      }
      // A share, whoever it is filed under: not a folder to stat per row.
      if (path.startsWith(r'\\') || path.startsWith('//')) return false;
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

  /// Selecting a project scans nothing. It used to start a full CLI-store
  /// import, so every click and expand walked every store again.
  void select(String? id) => state = id;
}

/// When the CLI stores were last read, and for which project. §19: a reading
/// is shown with its age, and *no* reading says so rather than saying nothing.
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
    byProject: {
      ...state.byProject,
      projectId: ref.read(clockProvider).nowUtc(),
    },
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
