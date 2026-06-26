import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/domain/environment_path.dart';
import 'package:chitragupta/src/features/projects/data/project_dao.dart';
import 'package:chitragupta/src/features/repositories/data/repository_dao.dart';
import 'package:chitragupta/src/features/sessions/data/session_dao.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late SessionDao dao;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    dao = SessionDao(db);
  });
  tearDown(() => db.close());

  test('insert then read round-trips a session without a worktree', () {
    final s = session();
    dao.insert(s);
    final loaded = dao.getById('s1')!;
    expect(loaded, s);
    expect(loaded.useWorktree, isFalse);
    expect(loaded.worktree, isNull);
  });

  test('persists a per-session worktree choice and location', () {
    final s = session(
      useWorktree: true,
      worktree: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo\app-wt',
      ),
    );
    dao.insert(s);
    final loaded = dao.getById('s1')!;
    expect(loaded.useWorktree, isTrue);
    expect(loaded.worktree!.path, r'C:\src\demo\app-wt');
  });

  test('updateStatus changes only the status', () {
    dao.insert(session());
    dao.updateStatus('s1', SessionStatus.running);
    expect(dao.getById('s1')!.status, SessionStatus.running);
  });

  test('getByRepository filters by repository', () {
    dao.insert(session(id: 's1'));
    dao.insert(session(id: 's2', title: 'Other'));
    expect(dao.getByRepository('r1').length, 2);
    expect(dao.getByRepository('rX'), isEmpty);
  });

  test('deleting the repository cascades to its sessions', () {
    dao.insert(session());
    RepositoryDao(db).delete('r1');
    expect(dao.getById('s1'), isNull);
  });
}
