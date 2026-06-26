import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/application/session_repositories_service.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_repository_dao.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionRepositoryDao linkDao;
  late SessionRepositoriesService service;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db)
      ..insert(project(id: 'p1'))
      ..insert(project(id: 'p2', name: 'Other'));
    RepositoryDao(db)
      ..insert(repository(id: 'r1', projectId: 'p1', name: 'app'))
      ..insert(repository(id: 'r2', projectId: 'p1', name: 'api'))
      ..insert(repository(id: 'rX', projectId: 'p2', name: 'other'));
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(repositoryId: 'r1'));
    linkDao = SessionRepositoryDao(db);
    linkDao.link('s1', 'r1', role: SessionRepositoryRole.primary);
    service = SessionRepositoriesService(
      sessionDao: SessionDao(db),
      repositoryDao: RepositoryDao(db),
      linkDao: linkDao,
    );
  });
  tearDown(() => db.close());

  test('links list the primary first', () {
    linkDao.link('s1', 'r2');
    final links = linkDao.linksFor('s1');
    expect(links.first.isPrimary, isTrue);
    expect(links.map((l) => l.repositoryId), ['r1', 'r2']);
  });

  test('attach adds a repository from the same project', () {
    service.attach('s1', 'r2');
    expect(service.forSession('s1').map((r) => r.name), ['app', 'api']);
  });

  test('attach rejects a repository from a different project', () {
    expect(
      () => service.attach('s1', 'rX'),
      throwsA(isA<SessionRepositoryException>()),
    );
    expect(service.forSession('s1').length, 1);
  });

  test('detach removes an additional repository but not the primary', () {
    service.attach('s1', 'r2');
    service.detach('s1', 'r2');
    expect(service.forSession('s1').map((r) => r.id), ['r1']);

    service.detach('s1', 'r1'); // primary is protected
    expect(service.forSession('s1').map((r) => r.id), ['r1']);
  });

  test('deleting the session cascades its repository links', () {
    service.attach('s1', 'r2');
    SessionDao(db).delete('s1');
    expect(linkDao.linksFor('s1'), isEmpty);
  });
}
