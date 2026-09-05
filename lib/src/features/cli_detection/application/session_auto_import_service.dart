import '../../../core/process/path_translator.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../environments/domain/environment_kind.dart';
import '../../environments/domain/environment_path.dart';
import '../../environments/domain/execution_environment.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/data/session_dao.dart';
import '../data/claude_store_reader.dart';
import '../data/imported_session_dao.dart';
import '../data/store_scan_worker.dart';
import '../domain/detected_session.dart';
import '../domain/imported_session.dart';
import 'cli_detection_service.dart';
import 'detected_project_merger.dart';
import 'project_import_service.dart';

/// Scans the CLI stores and imports any existing sessions whose folder matches a
/// repository. Idempotent (dedupes by `(cli, externalId)`).
///
/// **Runs once per app lifecycle**, after the first frame, plus whenever the
/// user asks — see `ProjectsController.importCliSessionsOnce`. It used to run
/// on every project expand *and* every project selection, which on a workspace
/// of five projects meant five concurrent walks of every store on the isolate
/// that draws.
///
/// The walk itself happens on the store-scan worker isolate, as a queue of
/// per-CLI jobs, and rows are written as each job lands rather than after the
/// slowest one.
class SessionAutoImportService {
  SessionAutoImportService({
    required this.locator,
    required this.scan,
    required this.environmentDao,
    required this.importedSessionDao,
    required this.sessionDao,
    required this.ids,
    required this.clock,
    this.translator = const PathTranslator(),
    this.narrowClaudeStore = true,
  });

  final CliStoreLocator locator;

  /// Where the stores are actually read. The seam that puts the walk on the
  /// worker isolate, and the one a test overrides.
  final Stream<StoreScanChunk> Function(StoreScanRequest) scan;

  final ExecutionEnvironmentDao environmentDao;
  final ImportedSessionDao importedSessionDao;
  final SessionDao sessionDao;
  final IdGenerator ids;
  final Clock clock;
  final PathTranslator translator;

  /// Whether to read only the Claude store directories the given repositories
  /// encode to. Off makes this read every directory, which is what a machine
  /// whose Claude build encodes paths differently would need — see
  /// [claudeStoreDirectoryName] for how the rule was verified.
  final bool narrowClaudeStore;

  Future<ImportSummary> importForRepositories(List<Repository> repos) async {
    if (repos.isEmpty) return const ImportSummary();
    final environments = environmentDao.getAll();
    final stores = await locator.locate(environments);
    final byId = {for (final e in environments) e.id: e};

    // Exact canonical paths, so a session that ran in a **subfolder** of a
    // repository is not filed under it: it canonicalises to its own key and
    // becomes its own project, which is what the CLI's own store already says.
    final byKey = <String, Repository>{};
    final directories = <String>{};
    for (final repo in repos) {
      final env = byId[repo.path.environmentId];
      final (key, _) = canonicalProjectPath(repo.path, env, translator);
      byKey[key] = repo;
      for (final cwd in _spellings(repo.path, env)) {
        directories.add(claudeStoreDirectoryName(cwd).toLowerCase());
      }
    }

    var imported = 0;
    final chunks = scan(
      StoreScanRequest(
        stores: stores,
        claudeDirectories: narrowClaudeStore ? directories : null,
      ),
    );
    await for (final chunk in chunks) {
      imported += _import(chunk.sessions, byKey, byId);
    }
    return ImportSummary(sessions: imported);
  }

  int _import(
    List<DetectedSession> sessions,
    Map<String, Repository> byKey,
    Map<String, ExecutionEnvironment> byId,
  ) {
    var imported = 0;
    final now = clock.nowUtc();
    for (final session in sessions) {
      if (session.cwd.path.trim().isEmpty) continue;
      final (key, _) = canonicalProjectPath(
        session.cwd,
        byId[session.environmentId],
        translator,
      );
      final repo = byKey[key];
      if (repo == null) continue;
      // A session started in Karmashala also appears in the CLI store. Keep the
      // native row as the single representation instead of importing a
      // duplicate history row beside it.
      if (sessionDao.getByExternalSessionId(session.sessionId) != null) {
        continue;
      }
      final added = importedSessionDao.insertIfAbsent(
        ImportedSession(
          id: ids.newId(),
          repositoryId: repo.id,
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
      );
      if (added) imported++;
    }
    return imported;
  }

  /// Every way a CLI could have written this folder's path down.
  ///
  /// The same folding [canonicalProjectPath] does, in the other direction: a
  /// repository on `/mnt/c/…` in WSL is `C:\…` to a Claude Code run from
  /// Windows, and both stores are read. Selected by [EnvironmentKind], never by
  /// a platform check, so a macOS build simply yields the one spelling.
  Iterable<String> _spellings(EnvironmentPath path, ExecutionEnvironment? env) {
    final trimmed = path.path.replaceAll(RegExp(r'[\\/]+$'), '');
    final out = <String>{trimmed};
    if (env == null) return out;
    try {
      if (env.kind == EnvironmentKind.wsl) {
        out.add(translator.wslMountToWindowsDrive(trimmed));
      } else if (usesWindowsPaths(env.kind)) {
        out.add(translator.windowsDriveToWslMount(trimmed));
      }
    } on PathTranslationException {
      // Not a drive-backed path; the one spelling is all there is.
    }
    return out;
  }
}
