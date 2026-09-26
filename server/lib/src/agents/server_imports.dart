import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_git/repositories.dart';

import '../data/data_service.dart';

/// **The CLI import, by the server**: it reads every agent's own store on
/// its machine (each through its adapter's reader — nothing here names an
/// agent), merges what it found into projects by folder, and writes the
/// imported history itself — a project and a checkout per folder, found or
/// created, and each conversation as a record unless one is recorded or a
/// session row already runs it (the sessions domain's own rule).
class ServerImports {
  ServerImports({
    required DataService data,
    required CliStoreLocator stores,
    required SqliteRowReader readRows,
    required this.ids,
    this.clock = const SystemClock(),
    AgentRegistry registry = AgentRegistry.builtIn,
    this.translator = const PathTranslator(),
  }) : _data = data,
       _stores = stores,
       _detection = CliDetectionService(
         readRows: readRows,
         registry: registry,
         translator: translator,
       );

  final DataService _data;
  final CliStoreLocator _stores;
  final CliDetectionService _detection;
  final IdGenerator ids;
  final Clock clock;
  final PathTranslator translator;

  /// Every conversation the stores hold, merged into projects. Imports
  /// nothing.
  Future<List<DetectedProject>> scan() async {
    final environments = _data.environments;
    final stores = await _stores.locate(environments);
    return mergeDetectedProjects(await _detection.readStores(stores), {
      for (final environment in environments) environment.id: environment,
    }, translator: translator);
  }

  /// Imports [detected]: a project and a checkout per folder, found or
  /// created, then each conversation as history.
  Future<ImportSummary> add(List<DetectedProject> detected) async {
    var summary = const ImportSummary();
    for (final project in detected) {
      summary = summary + _addOne(project);
    }
    return summary;
  }

  ImportSummary _addOne(DetectedProject detected) {
    final all = [...detected.sessions, ...detected.subagentSessions];
    if (all.isEmpty) return const ImportSummary();
    final root = all.first.cwd;
    final itself = [
      DiscoveredRepository(name: _basename(root.path), path: root),
    ];
    final workspace = _data.applyAsServer(const WorkspaceList());
    var addedProjects = 0;
    var addedRepositories = 0;
    Repository? repository;
    final project = workspace.projects
        .where((project) => project.root == root)
        .firstOrNull;
    if (project == null) {
      final created = _data.applyAsServer(
        ProjectCreate(
          projectName: _basename(root.path),
          root: root,
          found: itself,
        ),
      );
      addedProjects = 1;
      addedRepositories = created.repositories.length;
      repository = created.repositories.firstOrNull;
    } else {
      repository = _checkoutAt(workspace.repositories, project.id, root);
      if (repository == null) {
        final added = _data.applyAsServer(
          CheckoutsAdd(projectId: project.id, found: itself, orRoot: false),
        );
        addedRepositories = added.length;
        repository =
            added.firstOrNull ??
            _checkoutAt(
              _data.applyAsServer(const WorkspaceList()).repositories,
              project.id,
              root,
            );
      }
    }
    if (repository == null) return const ImportSummary();
    return ImportSummary(
      projects: addedProjects,
      repositories: addedRepositories,
      sessions: _record(all, (_) => repository!.id),
    );
  }

  /// Imports, as history, every conversation the stores hold for checkouts
  /// [repositoryIds] — by exact folder, so one that ran in a subfolder stays
  /// its own project, as the store says. Reads only the store directories
  /// those folders encode to, where a store is addressable that way.
  Future<ImportSummary> forRepositories(List<String> repositoryIds) async {
    final wanted = repositoryIds.toSet();
    final repositories = [
      for (final repository
          in _data.applyAsServer(const WorkspaceList()).repositories)
        if (wanted.contains(repository.id)) repository,
    ];
    if (repositories.isEmpty) return const ImportSummary();
    final environments = _data.environments;
    final byId = {for (final e in environments) e.id: e};
    final byKey = <String, Repository>{};
    final directories = <String>{};
    for (final repository in repositories) {
      final environment = byId[repository.path.environmentId];
      final (key, _) = canonicalProjectPath(
        repository.path,
        environment,
        translator,
      );
      byKey[key] = repository;
      directories.addAll(_spellings(repository.path, environment));
    }
    final sessions = await _detection.readStores(
      await _stores.locate(environments),
      workingDirectories: directories,
    );
    return ImportSummary(
      sessions: _record(sessions, (session) {
        if (session.cwd.path.trim().isEmpty) return null;
        final (key, _) = canonicalProjectPath(
          session.cwd,
          byId[session.environmentId],
          translator,
        );
        return byKey[key]?.id;
      }),
    );
  }

  /// A project's new checkouts were recorded (an agent's `project_add`):
  /// imports their history, as the app's auto-import does for the UI's.
  Future<void> checkoutsRecorded(List<Repository> added) async {
    if (added.isEmpty) return;
    await forRepositories([for (final repository in added) repository.id]);
  }

  /// Records each of [sessions] under the checkout [checkoutOf] names (none:
  /// skipped); answers how many were new.
  int _record(
    List<DetectedSession> sessions,
    String? Function(DetectedSession session) checkoutOf,
  ) {
    final now = clock.nowUtc();
    var recorded = 0;
    for (final session in sessions) {
      final repositoryId = checkoutOf(session);
      if (repositoryId == null) continue;
      final added = _data.applyAsServer(
        ImportedAdd(
          ImportedSession(
            id: ids.newId(),
            repositoryId: repositoryId,
            cli: session.cli,
            externalId: session.sessionId,
            environmentId: session.environmentId,
            filePath: session.filePath,
            storeHome: session.storeHome,
            isSubagent: session.isSubagent,
            preview: session.preview,
            title: session.title,
            updatedAt: session.modifiedAt,
            createdAt: now,
          ),
        ),
      );
      if (added) recorded++;
    }
    return recorded;
  }

  static Repository? _checkoutAt(
    List<Repository> repositories,
    String projectId,
    EnvironmentPath path,
  ) {
    for (final repository in repositories) {
      if (repository.projectId == projectId && repository.path == path) {
        return repository;
      }
    }
    return null;
  }

  /// Every way a CLI could have written this folder down: `/mnt/c/…` in WSL
  /// is `C:\…` to a Windows CLI, and both stores are read.
  Iterable<String> _spellings(
    EnvironmentPath path,
    ExecutionEnvironment? environment,
  ) {
    final trimmed = path.path.replaceAll(RegExp(r'[\\/]+$'), '');
    final out = <String>{trimmed};
    if (environment == null) return out;
    try {
      if (environment.kind == EnvironmentKind.wsl) {
        out.add(translator.wslMountToWindowsDrive(trimmed));
      } else if (usesWindowsPaths(environment.kind)) {
        out.add(translator.windowsDriveToWslMount(trimmed));
      }
    } on PathTranslationException {
      // Not a drive-backed path; the one spelling is all there is.
    }
    return out;
  }

  static String _basename(String path) {
    final parts = path
        .replaceAll(RegExp(r'[\\/]+$'), '')
        .split(RegExp(r'[\\/]'));
    return parts.isEmpty || parts.last.isEmpty ? path : parts.last;
  }
}
