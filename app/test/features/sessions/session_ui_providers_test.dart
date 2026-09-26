import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:agent_cli/stream.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/git/application/changes_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_engine_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_ui_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

void main() {
  late TestMachine db;
  late ProviderContainer container;

  setUp(() async {
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        chatProtocolResolverProvider.overrideWithValue(
          (agentId) => FakeChatProtocol(agentId: agentId),
        ),
      ],
    );
  });
  tearDown(() {
    container.dispose();
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
          permission: ResolvedPermission.none,
        );
    container.read(sessionsRevisionProvider.notifier).bump();

    final sessions = container.read(sessionsForSelectedRepositoryProvider);
    expect(sessions.single.id, session.id);

    // The engine persisted the started + greeting events.
    final eventDao = db.server.eventRows;
    for (var i = 0; i < 200; i++) {
      if (eventDao.countForSession(session.id) >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(eventDao.countForSession(session.id), greaterThanOrEqualTo(2));
  });
}
