import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/agent_store_server_providers.dart';
import 'package:karmashala/src/features/cli_detection/data/agent_store_servers.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_archive_service.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session/launch.dart';
import 'package:logging/logging.dart';

import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../../support/fake_codex_app_server.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// **Two paths that decided things in silence.**
///
/// `SessionLauncher` and `SessionHandoffService` each write one line saying
/// what they decided, and a test reads it back — so the facts that tell their
/// outcomes apart cannot be quietly dropped later. `session_actions` wrote only
/// on the destructive path and the archive path wrote nothing at all, which
/// left four choices with no trace anywhere: which route a rename took into the
/// CLI's own store, whether a resume reattached or started a second process,
/// which of three paths carried a message into an agent, and why an archive
/// left the worktree exactly where it was.
void main() {
  /// Captures the app's own log for the length of a test.
  List<LogRecord> captureLogs() {
    final previous = Diagnostics.instance;
    final records = <LogRecord>[];
    Diagnostics.instance = Diagnostics(echoToConsole: false);
    AppLogger.initialize(onRecord: records.add);
    addTearDown(() {
      Diagnostics.instance = previous;
      AppLogger.initialize();
    });
    return records;
  }

  String linesOn(List<LogRecord> records, String channel) => records
      .where((r) => r.loggerName == channel)
      .map((r) => r.message)
      .join('\n');

  group('a rename says what the CLI store did with it', () {
    late AppDatabase db;
    late FakeDataServer dataServer;
    late DataClient data;
    late FakeCodexAppServer server;
    late FakeCommandRunner runner;

    setUp(() async {
      db = AppDatabase.memory();
      dataServer = FakeDataServer()..mirrorInto(db);
      data = await dataServer.connect();
      server = FakeCodexAppServer();
      runner = FakeCommandRunner(processFactory: (_) => server);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      dataServer.projectRows.insert(project());
      dataServer.repositoryRows.insert(repository());
    });
    tearDown(() => db.close());

    void seed({String? externalId = 'u1'}) {
      AgentInstallationDao(
        db,
      ).insert(agentInstallation(agentId: AgentIds.codex));
      SessionDao(db).insert(
        session(title: 'Session 0').copyWith(externalSessionId: externalId),
      );
    }

    ProviderContainer mount() {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          dataClientProvider.overrideWithValue(data),
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

    test('a Codex thread is named through the app-server', () async {
      seed();
      final records = captureLogs();

      await mount().read(sessionActionsProvider).renameNative('s1', 'Renamed');

      final line = linesOn(records, 'sessions.actions');
      expect(line, contains('Renamed s1'));
      expect(line, contains('byUser=true'));
      expect(line, contains('store=app-server'));
    });

    test('a row with no conversation behind it says so, and is not a '
        'failure', () async {
      // The rename is applied and published either way; the store half is what
      // the line exists to distinguish.
      seed(externalId: null);
      final records = captureLogs();

      await mount().read(sessionActionsProvider).renameNative('s1', 'Renamed');

      expect(
        linesOn(records, 'sessions.actions'),
        contains('store=no-conversation'),
      );
      expect(SessionDao(db).getById('s1')!.title, 'Renamed');
    });
  });

  group('continuing a session says which path carried the message', () {
    test('a live pane is typed into, not messaged', () async {
      // Chat and terminal are two views of one session and there is exactly one
      // write path into the agent — but which of the three was taken decides
      // whether a second process was started, and nothing on screen says.
      final db = AppDatabase.memory();
      final server = FakeDataServer()..mirrorInto(db);
      final data = await server.connect();
      addTearDown(db.close);
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      AgentInstallationDao(db).insert(agentInstallation(agentId: 'demo'));

      final container = ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
        ],
      );
      addTearDown(container.dispose);

      final launched = await container
          .read(sessionLauncherProvider)
          .launch(
            SessionLaunchRequest(
              repository: repository(),
              installation: agentInstallation(agentId: 'demo'),
              title: 'Work',
              purpose: SessionPurpose.newSession,
            ),
          );

      final records = captureLogs();
      await container
          .read(sessionActionsProvider)
          .continueSession(launched.session.id, 'carry on');

      expect(
        linesOn(records, 'sessions.actions'),
        contains('Continued ${launched.session.id}: typed into its pane'),
      );
    });
  });

  group('an archive says what it decided', () {
    late AppDatabase db;
    late FakeDataServer server;
    late DataClient data;
    late FakeCommandRunner git;
    var statusOutput = '';

    const worktree = EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\src\.karmashala-worktrees\app-s1',
    );

    setUp(() async {
      statusOutput = '';
      db = AppDatabase.memory();
      server = FakeDataServer()..mirrorInto(db);
      data = await server.connect();
      ExecutionEnvironmentDao(db).upsert(windowsEnv());
      server.projectRows.insert(project());
      server.repositoryRows.insert(repository());
      AgentInstallationDao(db).insert(agentInstallation());
      git = FakeCommandRunner(
        responder: (request) => request.arguments.contains('status')
            ? CommandResult(exitCode: 0, stdout: statusOutput, stderr: '')
            : const CommandResult(exitCode: 0, stdout: '', stderr: ''),
      );
    });
    tearDown(() => db.close());

    void addSession({EnvironmentPath? at = worktree}) => SessionDao(db).insert(
      Session(
        id: 's1',
        repositoryId: 'r1',
        agentInstallationId: 'a1',
        title: 'Fix the login',
        useWorktree: at != null,
        worktree: at,
        status: SessionStatus.completed,
        createdAt: testTime,
      ),
    );

    SessionArchiveService service() {
      final container = ProviderContainer(
        overrides: [
          dataClientProvider.overrideWithValue(data),
          ...fakeTerminalOverrides(database: db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          commandRunnerFactoryProvider.overrideWithValue(
            FakeCommandRunnerFactory(fallback: git),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container.read(sessionArchiveServiceProvider);
    }

    test('a worktree that went says so', () async {
      addSession();
      final records = captureLogs();

      await service().archive('s1');

      final line = linesOn(records, 'sessions.archive');
      expect(line, contains('Archive s1: archived'));
      expect(line, contains('discardUncommitted=false'));
      expect(line, contains('uncommitted=0'));
    });

    test('a refusal names itself and counts what stopped it', () async {
      addSession();
      statusOutput = ' M lib/a.dart\n M lib/b.dart\n';
      final records = captureLogs();

      final outcome = await service().archive('s1');

      expect(outcome.isArchived, isFalse);
      final line = linesOn(records, 'sessions.archive');
      expect(line, contains('Archive s1: uncommittedChanges'));
      expect(line, contains('uncommitted=2'));
    });

    test('a session with no worktree of its own is a refusal too', () async {
      // The one a user is most likely to report as "nothing happened": there
      // was never a directory to remove.
      addSession(at: null);
      final records = captureLogs();

      await service().archive('s1');

      expect(
        linesOn(records, 'sessions.archive'),
        contains('Archive s1: noWorktree'),
      );
    });
  });
}
