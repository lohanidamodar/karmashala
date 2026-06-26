import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/features/agents/application/agent_providers.dart';
import 'package:chitragupta/src/features/environments/application/environment_providers.dart';
import 'package:chitragupta/src/features/projects/application/project_providers.dart';
import 'package:chitragupta/src/features/repositories/application/repository_providers.dart';
import 'package:chitragupta/src/features/sessions/application/session_providers.dart';
import 'package:chitragupta/src/features/sessions/domain/session_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

/// End-to-end persistence through the repository-layer providers: build the full
/// Project → Repository → AgentInstallation → Session → SessionEvent graph and
/// read it back, then verify cascade deletion.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  test('providers are wired to the same overridden database', () {
    final envDao = container.read(executionEnvironmentDaoProvider);
    envDao.upsert(windowsEnv());
    // A different provider sees the same write.
    expect(container.read(projectDaoProvider).getAll(), isEmpty);
    expect(envDao.getById('windows'), isNotNull);
  });

  test('full domain graph persists and reads back', () {
    container.read(executionEnvironmentDaoProvider).upsert(windowsEnv());
    container.read(projectDaoProvider).insert(project());
    container.read(repositoryDaoProvider).insert(repository());
    container.read(agentInstallationDaoProvider).insert(agentInstallation());

    final sessionDao = container.read(sessionDaoProvider);
    sessionDao.insert(session(status: SessionStatus.running));

    final eventDao = container.read(sessionEventDaoProvider);
    eventDao.append(event(type: 'session.started'));
    eventDao.append(event(type: 'message.agent'));

    expect(container.read(projectDaoProvider).getAll().single.name, 'Demo');
    expect(
      container.read(repositoryDaoProvider).getByProject('p1').single.name,
      'app',
    );
    expect(sessionDao.getById('s1')!.status, SessionStatus.running);
    expect(eventDao.listForSession('s1').map((e) => e.seq), [0, 1]);
  });

  test(
    'deleting a project cascades through repositories, sessions, events',
    () {
      container.read(executionEnvironmentDaoProvider).upsert(windowsEnv());
      container.read(projectDaoProvider).insert(project());
      container.read(repositoryDaoProvider).insert(repository());
      container.read(agentInstallationDaoProvider).insert(agentInstallation());
      container.read(sessionDaoProvider).insert(session());
      container.read(sessionEventDaoProvider).append(event());

      container.read(projectDaoProvider).delete('p1');

      expect(container.read(repositoryDaoProvider).getAll(), isEmpty);
      expect(container.read(sessionDaoProvider).getAll(), isEmpty);
      expect(container.read(sessionEventDaoProvider).countForSession('s1'), 0);
    },
  );
}
