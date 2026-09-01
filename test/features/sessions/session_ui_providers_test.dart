import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/agents/data/fake_agent_adapter.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_engine_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_event_dao.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        agentAdapterResolverProvider.overrideWithValue(
          (agentId) => FakeAgentAdapter(agentId: agentId),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  test('sessions list is empty until a repository is selected', () {
    expect(container.read(sessionsForSelectedRepositoryProvider), isEmpty);
    container.read(selectedRepositoryIdProvider.notifier).select('r1');
    expect(container.read(sessionsForSelectedRepositoryProvider), isEmpty);
  });

  test('starting a session lists it after a revision bump', () async {
    container.read(selectedRepositoryIdProvider.notifier).select('r1');

    final session = await container
        .read(sessionEngineProvider)
        .start(
          repository: repository(),
          installation: agentInstallation(),
          title: 'Work',
        );
    container.read(sessionsRevisionProvider.notifier).bump();

    final sessions = container.read(sessionsForSelectedRepositoryProvider);
    expect(sessions.single.id, session.id);

    // The engine persisted the started + greeting events.
    final eventDao = SessionEventDao(db);
    for (var i = 0; i < 200; i++) {
      if (eventDao.countForSession(session.id) >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(eventDao.countForSession(session.id), greaterThanOrEqualTo(2));
  });
}
