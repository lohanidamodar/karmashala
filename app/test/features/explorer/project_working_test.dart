import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/explorer/application/project_working.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/notifications/application/session_status_registry.dart';
import 'package:karmashala_notifications/watched.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:karmashala_agent_reporting/status.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_ui/rows.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/workspace_mirror.dart';

/// **Whether a project's running mark turns.** "Running" is the row's record
/// of what it started; "working" is the agent in a turn right now, and it comes
/// from the one status registry — subscribed to, never polled, and narrowed so
/// that a turn starting in one project wakes that project's header alone.
void main() {
  late AppDatabase db;
  late FakeDataServer server;
  late AgentHookReceiver receiver;
  late SessionStatusRegistry registry;
  late List<WatchedSession> watched;
  late ProviderContainer container;

  WatchedSession watch(String row) => WatchedSession(
    key: AgentSessionKey(AgentIds.claudeCode, 'cli-$row'),
    label: row,
    openId: row,
    imported: false,
  );

  setUp(() async {
    db = AppDatabase.memory();
    server = FakeDataServer()..mirrorInto(db);
    ExecutionEnvironmentDao(db).upsert(posixEnv());
    AgentInstallationDao(db).insert(agentInstallation());
    for (final (projectId, sessions) in [
      ('p1', ['s1', 's2']),
      ('p2', ['s3']),
    ]) {
      server.projectRows.insert(
        project(id: projectId, name: projectId, path: '/w/$projectId'),
      );
      server.repositoryRows.insert(
        repository(
          id: 'r-$projectId',
          projectId: projectId,
          name: 'repo',
          path: '/w/$projectId',
        ),
      );
      for (final id in sessions) {
        SessionDao(db).insert(
          Session(
            id: id,
            repositoryId: 'r-$projectId',
            agentInstallationId: 'a1',
            title: id,
            useWorktree: false,
            status: SessionStatus.running,
            createdAt: testTime,
          ),
        );
      }
    }

    final clock = FixedClock(testTime);
    final reports = AgentHookReports();
    receiver = AgentHookReceiver(
      registry: AgentRegistry.builtIn,
      reports: reports,
      clock: clock,
    );
    watched = [watch('s1'), watch('s2'), watch('s3')];
    registry = SessionStatusRegistry(
      statusService: AgentStatusService(
        registry: AgentRegistry.builtIn,
        hookReports: reports,
        clock: clock,
      ),
      agents: AgentRegistry.builtIn,
      loadSessions: () => watched,
      clock: clock,
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        await server.override(),
        clockProvider.overrideWithValue(clock),
        sessionStatusRegistryProvider.overrideWithValue(registry),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    registry.dispose();
    db.close();
  });

  void hook(String row, String event) {
    receiver.handle(
      agentId: AgentIds.claudeCode,
      event: event,
      body: '{"session_id":"cli-$row"}',
    );
    registry.hookReported(AgentSessionKey(AgentIds.claudeCode, 'cli-$row'));
  }

  test(
    'a turn starting counts in its own project, and ending uncounts',
    () async {
      await registry.cycle();
      final counts = container.listen(projectWorkingCountsProvider, (_, _) {});
      expect(counts.read(), isEmpty);

      hook('s1', 'PreToolUse');
      expect(counts.read(), {'p1': 1});
      hook('s2', 'PreToolUse');
      hook('s3', 'PreToolUse');
      expect(counts.read(), {'p1': 2, 'p2': 1});

      hook('s1', 'Stop');
      expect(counts.read(), {'p1': 1, 'p2': 1});
    },
  );

  test(
    'a session already working when the Explorer opens is counted',
    () async {
      await registry.cycle();
      hook('s3', 'PreToolUse');
      await registry.cycle();

      expect(container.read(projectWorkingCountsProvider), {'p2': 1});
    },
  );

  test('the summary carries it, and a turn wakes one project', () async {
    await registry.cycle();
    final summaries = <String, List<ProjectSummary>>{'p1': [], 'p2': []};
    for (final id in summaries.keys) {
      container.listen(
        projectSummaryProvider(id),
        (_, next) => summaries[id]!.add(next),
        fireImmediately: true,
      );
    }
    expect(summaries['p1']!.single.working, 0);
    expect(summaries['p1']!.single.running, 2);

    hook('s1', 'PreToolUse');
    await container.pump();

    expect(summaries['p1']!.last.working, 1);
    expect(summaries['p1']!.last.running, 2, reason: 'running is the row\'s');
    expect(summaries['p2'], hasLength(1), reason: 'the other header slept');
  });

  test('a cycle that reconfirms every status moves nothing', () async {
    await registry.cycle();
    hook('s1', 'PreToolUse');
    var changes = 0;
    container.listen(workingSessionsProvider, (_, _) => changes++);

    await registry.cycle();
    await registry.cycle();

    expect(changes, 0);
    expect(container.read(workingSessionsProvider), {'s1'});
  });

  test(
    'a working session that stops being watched stops being counted',
    () async {
      await registry.cycle();
      final counts = container.listen(projectWorkingCountsProvider, (_, _) {});
      hook('s1', 'PreToolUse');
      expect(counts.read(), {'p1': 1});

      // It ended, so the loader no longer offers it: no status moves, it goes.
      watched = [watch('s2'), watch('s3')];
      await registry.cycle();
      await Future<void>.delayed(Duration.zero);

      expect(counts.read(), isEmpty);
    },
  );

  test('with nothing working it reads no table', () async {
    await registry.cycle();
    container.read(projectWorkingCountsProvider);
    expect(container.exists(sessionProjectIdsProvider), isFalse);
  });
}
