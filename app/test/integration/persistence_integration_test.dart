import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/environments/application/environment_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/fake_data_server.dart';
import '../support/workspace_mirror.dart';

/// End-to-end persistence through the repository-layer providers: build the full
/// Project → Repository → AgentInstallation → Session → SessionEvent graph and
/// read it back, then verify cascade deletion.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeDataServer server;

  setUp(() {
    db = AppDatabase.memory();
    // Sessions are still in the database; their foreign keys reach the
    // workspace rows the server writes, so those are mirrored there.
    server = FakeDataServer()..mirrorInto(db);
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
    expect(container.read(sessionDaoProvider).getAll(), isEmpty);
    expect(envDao.getById('windows'), isNotNull);
  });

  test('full domain graph persists and reads back', () {
    container.read(executionEnvironmentDaoProvider).upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    container.read(agentInstallationDaoProvider).insert(agentInstallation());

    final sessionDao = container.read(sessionDaoProvider);
    sessionDao.insert(session(status: SessionStatus.running));

    final eventDao = container.read(sessionEventDaoProvider);
    eventDao.append(event(type: 'session.started'));
    eventDao.append(event(type: 'message.agent'));

    expect(server.projectRows.getAll().single.name, 'Demo');
    expect(server.repositoryRows.getByProject('p1').single.name, 'app');
    expect(sessionDao.getById('s1')!.status, SessionStatus.running);
    expect(eventDao.listForSession('s1').map((e) => e.seq), [0, 1]);
  });

  test(
    'deleting a project cascades through repositories, sessions, events',
    () {
      container.read(executionEnvironmentDaoProvider).upsert(windowsEnv());
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      container.read(agentInstallationDaoProvider).insert(agentInstallation());
      container.read(sessionDaoProvider).insert(session());
      container.read(sessionEventDaoProvider).append(event());

      server.projectRows.delete('p1');

      expect(server.repositoryRows.getAll(), isEmpty);
      expect(container.read(sessionDaoProvider).getAll(), isEmpty);
      expect(container.read(sessionEventDaoProvider).countForSession('s1'), 0);
    },
  );
}
