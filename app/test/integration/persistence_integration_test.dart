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

/// End-to-end persistence through the providers: the domains read and written
/// through the server (environments, installations, the workspace, sessions
/// and their event log) build the full Project → Repository →
/// AgentInstallation → Session → SessionEvent graph and read it back. The server's own cascades are tested at the server
/// (server/test/data).
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late FakeDataServer server;

  setUp(() async {
    db = AppDatabase.memory();
    // The installations' foreign keys reach the workspace rows the server
    // writes, so those are mirrored there.
    server = FakeDataServer()..mirrorInto(db);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    db.close();
  });

  test('providers read the same server', () async {
    await container.read(environmentsDataProvider).put(windowsEnv());
    // A different provider sees the same write.
    expect(server.environmentRows.getById('windows'), isNotNull);
    expect(container.read(localEnvironmentProvider)?.id, 'windows');
    expect(container.read(sessionsDataProvider).getAll(), isEmpty);
  });

  test('full domain graph persists and reads back', () async {
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    expect(
      container.read(agentInstallationsDataProvider).getById('a1'),
      isNotNull,
    );

    final sessions = container.read(sessionsDataProvider);
    await sessions.create(session(status: SessionStatus.running));

    final records = container.read(sessionRecordsProvider);
    await records.appendAll([
      event(type: 'session.started'),
      event(type: 'message.agent'),
    ]);

    expect(server.projectRows.getAll().single.name, 'Demo');
    expect(server.repositoryRows.getByProject('p1').single.name, 'app');
    expect(sessions.getById('s1')!.status, SessionStatus.running);
    expect(server.sessionRows.getById('s1')!.status, SessionStatus.running);
    expect((await records.listForSession('s1')).map((e) => e.seq), [0, 1]);
  });
}
