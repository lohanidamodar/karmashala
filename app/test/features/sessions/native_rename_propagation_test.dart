import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart' show CodexStoreServerClient;
import 'package:karmashala/src/features/cli_detection/application/agent_store_server_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/agent_store_servers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_signals.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fake_codex_app_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'dart:async';

/// **A session Karmashala launched, renamed in Karmashala, reaching Codex.**
///
/// `renameNative` used to write the workspace row and stop there, so the one
/// case the app is meant to own end-to-end — launch a Codex session here, name
/// it here — was the case that never reached the store. The row already carries
/// the thread id as `externalSessionId`, and `thread/name/set` wants nothing
/// else, so this costs no walk over the CLI stores.
void main() {
  late AppDatabase db;
  late FakeCodexAppServer server;
  late FakeCommandRunner runner;
  late FakeDataServer data;

  setUp(() {
    db = AppDatabase(sqlite3.openInMemory());
    server = FakeCodexAppServer();
    runner = FakeCommandRunner(processFactory: (_) => server);
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    data = FakeDataServer()..mirrorInto(db);
    data
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository());
  });
  tearDown(() => db.close());

  void seedSession({
    String agentId = AgentIds.codex,
    String? externalId = 'u1',
  }) {
    AgentInstallationDao(db).insert(agentInstallation(agentId: agentId));
    data.sessionRows.insert(
      session(title: 'Session 0').copyWith(externalSessionId: externalId),
    );
  }

  Future<ProviderContainer> mount() async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await data.override(),
        agentStoreServersProvider.overrideWithValue(
          AgentStoreServers(
            runnerFactory: FakeCommandRunnerFactory(fallback: runner),
            environments: ExecutionEnvironmentDao(db),
            installations: AgentInstallationDao(db),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'renaming a Codex row tells Codex, and keeps the name the user own',
    () async {
      seedSession();
      final container = await mount();

      await container
          .read(sessionActionsProvider)
          .renameNative('s1', 'Renamed');

      expect(server.lastNameSet, {'threadId': 'u1', 'name': 'Renamed'});
      await container.read(sessionsDataProvider).settled();
      final row = data.sessionRows.getById('s1')!;
      expect(row.title, 'Renamed');
      expect(
        row.titleByUser,
        isTrue,
        reason: 'the flag that stops the CLI title sync taking the name back',
      );
    },
  );

  test('the workspace row is renamed before Codex is asked anything', () async {
    seedSession();
    final container = await mount();

    // Deliberately not awaited: everything the user sees must already have
    // happened by the time `renameNative` first suspends.
    unawaited(
      container.read(sessionActionsProvider).renameNative('s1', 'Renamed'),
    );

    expect(
      container.read(sessionsDataProvider).getById('s1')!.title,
      'Renamed',
    );
  });

  test('a row with no CLI conversation behind it asks nothing', () async {
    seedSession(externalId: null);
    final container = await mount();

    await container.read(sessionActionsProvider).renameNative('s1', 'Renamed');

    expect(runner.startRequests, isEmpty);
    expect(
      container.read(sessionsDataProvider).getById('s1')!.title,
      'Renamed',
    );
  });

  test('a Codex that will not start leaves the local rename applied', () async {
    seedSession();
    runner = FakeCommandRunner(throwError: StateError('no codex here'));
    final container = await mount();

    await container.read(sessionActionsProvider).renameNative('s1', 'Renamed');

    expect(
      container.read(sessionsDataProvider).getById('s1')!.title,
      'Renamed',
    );
  });

  test(
    'a Codex-side name notification updates the row and both title surfaces',
    () async {
      seedSession();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          await data.override(),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: runner),
          ),
        ],
      );
      addTearDown(container.dispose);
      final beforeSessions = container.read(sessionsRevisionProvider);
      final beforeTerminals = container
          .read(terminalSessionsControllerProvider)
          .titleRevision;
      final client = container
          .read(agentStoreServersProvider)
          .forEnvironment('windows', AgentIds.codex)!;

      await (client as CodexStoreServerClient).client.setThreadName(
        'u1',
        'Renamed in Codex',
      );

      await container.read(sessionsDataProvider).settled();
      final row = data.sessionRows.getById('s1')!;
      expect(row.title, 'Renamed in Codex');
      expect(row.titleByUser, isFalse);
      expect(container.read(sessionsRevisionProvider), beforeSessions + 1);
      expect(
        container.read(terminalSessionsControllerProvider).titleRevision,
        greaterThan(beforeTerminals),
      );
    },
  );
}
