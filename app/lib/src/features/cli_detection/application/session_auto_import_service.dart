import 'package:agent_cli/process.dart';
import 'package:karmashala_core/util.dart';
import '../../environments/data/execution_environment_dao.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:agent_cli/read.dart';
import '../data/imported_session_dao.dart';
import '../data/store_scan_worker.dart';
import 'detected_project_merger.dart';
import 'project_import_service.dart';

/// Scans the CLI stores and imports sessions whose folder matches a repository.
/// Idempotent, once per app lifecycle, and walked on the store-scan worker.
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
    this.narrowByDirectory = true,
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

  /// Whether to read only the store directories these repositories encode to,
  /// in a store addressable from a working directory. Off reads every
  /// directory, for a build that encodes paths differently.
  final bool narrowByDirectory;

  Future<ImportSummary> importForRepositories(List<Repository> repos) async {
    if (repos.isEmpty) return const ImportSummary();
    final environments = environmentDao.getAll();
    final stores = await locator.locate(environments);
    final byId = {for (final e in environments) e.id: e};

    // Exact canonical paths, so a session that ran in a *subfolder* of a
    // repository becomes its own project, as the CLI's own store already says.
    final byKey = <String, Repository>{};
    final directories = <String>{};
    for (final repo in repos) {
      final env = byId[repo.path.environmentId];
      final (key, _) = canonicalProjectPath(repo.path, env, translator);
      byKey[key] = repo;
      for (final cwd in _spellings(repo.path, env)) {
        directories.add(cwd);
      }
    }

    var imported = 0;
    final chunks = scan(
      StoreScanRequest(
        stores: stores,
        workingDirectories: narrowByDirectory ? directories : null,
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
      // A session started in Karmashala also appears in the CLI store; the
      // native row stays the single representation.
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

  /// Every way a CLI could have written this folder down: `/mnt/c/…` in WSL is
  /// `C:\…` to a Windows Claude Code, and both stores are read.
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
