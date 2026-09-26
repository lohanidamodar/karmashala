import 'package:karmashala_store/database.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/project_import_service.dart';
import 'package:karmashala/src/features/cli_detection/data/imported_session_dao.dart';
import 'package:agent_cli/read.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_projects/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProjectImportService service;
  late ImportedSessionDao importedDao;

  DetectedSession session(String id, {String? entrypoint}) => DetectedSession(
    cli: AgentIds.claudeCode,
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
      workspace: workspaceOver(db),
      importedSessionDao: importedDao,
      ids: SequentialIdGenerator(),
      clock: FixedClock(testTime),
    );
  });
  tearDown(() => db.close());

  test('imports a project, repository, and its sessions', () async {
    final summary = await service.importAll([
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

  test(
    're-importing the same sessions is a no-op (duplicates ignored)',
    () async {
      final input = [
        detected(sessions: [session('a')]),
      ];
      await service.importAll(input);
      final second = await service.importAll(input);

      expect(second.projects, 0);
      expect(second.repositories, 0);
      expect(second.sessions, 0);
      expect(ProjectDao(db).getAll().length, 1);
      expect(
        importedDao
            .getByRepository(RepositoryDao(db).getAll().single.id)
            .length,
        1,
      );
    },
  );
}
