import '../../../core/process/path_translator.dart';
import '../../../core/util/clock.dart';
import '../../../core/util/id_generator.dart';
import '../../environments/data/execution_environment_dao.dart';
import '../../repositories/domain/repository.dart';
import '../../sessions/data/session_dao.dart';
import '../data/imported_session_dao.dart';
import '../domain/imported_session.dart';
import 'cli_detection_service.dart';
import 'detected_project_merger.dart';
import 'project_import_service.dart';

/// Scans the CLI stores and imports any existing sessions whose folder matches a
/// repository — used right after a project is added so its history shows up
/// automatically. Idempotent (dedupes by `(cli, externalId)`).
class SessionAutoImportService {
  SessionAutoImportService({
    required this.locator,
    required this.detectionService,
    required this.environmentDao,
    required this.importedSessionDao,
    required this.sessionDao,
    required this.ids,
    required this.clock,
    this.translator = const PathTranslator(),
  });

  final CliStoreLocator locator;
  final CliDetectionService detectionService;
  final ExecutionEnvironmentDao environmentDao;
  final ImportedSessionDao importedSessionDao;
  final SessionDao sessionDao;
  final IdGenerator ids;
  final Clock clock;
  final PathTranslator translator;

  Future<ImportSummary> importForRepositories(List<Repository> repos) async {
    if (repos.isEmpty) return const ImportSummary();
    final environments = environmentDao.getAll();
    final stores = await locator.locate(environments);
    final byId = {for (final e in environments) e.id: e};
    final detected = await detectionService.detect(stores, byId);
    final byKey = {
      for (final project in detected) project.canonicalKey: project,
    };

    var imported = 0;
    for (final repo in repos) {
      final env = environmentDao.getById(repo.path.environmentId);
      final (key, _) = canonicalProjectPath(repo.path, env, translator);
      final match = byKey[key];
      if (match == null) continue;
      final now = clock.nowUtc();
      for (final session in [...match.sessions, ...match.subagentSessions]) {
        // A session started in Chitragupta also appears in the CLI store. Keep
        // the native row as the single representation instead of importing a
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
    }
    return ImportSummary(sessions: imported);
  }
}
