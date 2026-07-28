import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/domain/agent_kind.dart';
import 'package:chitragupta/src/features/cli_detection/application/project_import_service.dart';
import 'package:chitragupta/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:chitragupta/src/features/cli_detection/domain/detected_project.dart';
import 'package:chitragupta/src/features/cli_detection/domain/detected_session.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProjectImportService service;
  late ImportedSessionDao importedDao;

  DetectedSession session(String id, {String? entrypoint}) => DetectedSession(
    cli: AgentKind.claudeCode,
    sessionId: id,
    cwd: const EnvironmentPath(environmentId: 'windows', path: r'C:\src\app'),
    filePath: 'C:\\store\\$id.jsonl',
    storeHome: r'C:\store\.claude',
    title: 'Session $id',
    entrypoint: entrypoint,
  );

  DetectedProject detected({
    required List<DetectedSession> sessions,
    List<DetectedSession> subagents = const [],
  }) => DetectedProject(
    canonicalKey: r'c:\src\app',
    displayPath: r'C:\src\app',
    sessions: sessions,
    subagentSessions: subagents,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    importedDao = ImportedSessionDao(db);
    service = ProjectImportService(
      projectDao: ProjectDao(db),
      repositoryDao: RepositoryDao(db),
      importedSessionDao: importedDao,
      ids: SequentialIdGenerator(),
      clock: FixedClock(testTime),
    );
  });
  tearDown(() => db.close());

  test('imports a project, repository, and its sessions', () {
    final summary = service.importAll([
      detected(
        sessions: [session('a'), session('b')],
        subagents: [session('sub', entrypoint: 'sdk-cli')],
      ),
    ]);

    expect(summary.projects, 1);
    expect(summary.repositories, 1);
    expect(summary.sessions, 3); // a, b, sub
    expect(ProjectDao(db).getAll().single.name, 'app');
    final repo = RepositoryDao(db).getAll().single;
    expect(importedDao.getByRepository(repo.id).length, 3);
    expect(importedDao.getAll().length, 3);
  });

  test('re-importing the same sessions is a no-op (duplicates ignored)', () {
    final input = [
      detected(sessions: [session('a')]),
    ];
    service.importAll(input);
    final second = service.importAll(input);

    expect(second.projects, 0);
    expect(second.repositories, 0);
    expect(second.sessions, 0);
    expect(ProjectDao(db).getAll().length, 1);
    expect(
      importedDao.getByRepository(RepositoryDao(db).getAll().single.id).length,
      1,
    );
  });
}
