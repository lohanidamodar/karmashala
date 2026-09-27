import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/explorer/application/project_working.dart';
import 'package:karmashala/src/features/explorer/application/session_diff_stat.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_ui/rows.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';

/// **Whether a project's running mark turns.** "Running" is the row's record
/// of what it started; "working" is the agent in a turn right now, and it comes
/// from the server's statuses (slice 5c) — subscribed to, never polled, and
/// narrowed so that a turn starting in one project wakes that project's header
/// alone.
void main() {
  late TestMachine db;
  late FakeDataServer server;
  late ProviderContainer container;

  setUp(() async {
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(posixEnv());
    server.installationRows.insert(agentInstallation());
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
        db.server.sessionRows.insert(
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

    for (final row in ['s1', 's2', 's3']) {
      server.attention.statusOf(
        row,
        AgentActivityStatus.idle,
        sessionId: 'cli-$row',
        label: row,
      );
    }
    container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
  });

  tearDown(() => container.dispose());

  /// The server's word on [row]: in a turn ([working]) or at rest.
  void status(String row, {required bool working}) => server.attention.statusOf(
    row,
    working ? AgentActivityStatus.working : AgentActivityStatus.idle,
    sessionId: 'cli-$row',
    label: row,
  );

  test(
    'a turn starting counts in its own project, and ending uncounts',
    () async {
      final counts = container.listen(projectWorkingCountsProvider, (_, _) {});
      expect(counts.read(), isEmpty);

      status('s1', working: true);
      expect(counts.read(), {'p1': 1});
      status('s2', working: true);
      status('s3', working: true);
      expect(counts.read(), {'p1': 2, 'p2': 1});

      status('s1', working: false);
      expect(counts.read(), {'p1': 1, 'p2': 1});
    },
  );

  test(
    'a session already working when the Explorer opens is counted',
    () async {
      status('s3', working: true);

      expect(container.read(projectWorkingCountsProvider), {'p2': 1});
    },
  );

  test('the summary carries it, and a turn wakes one project', () async {
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

    status('s1', working: true);
    await container.pump();

    expect(summaries['p1']!.last.working, 1);
    expect(summaries['p1']!.last.running, 2, reason: 'running is the row\'s');
    expect(summaries['p2'], hasLength(1), reason: 'the other header slept');
  });

  test('the server saying the same again moves nothing', () async {
    status('s1', working: true);
    var changes = 0;
    container.listen(workingSessionsProvider, (_, _) => changes++);

    status('s1', working: true);
    status('s2', working: false);

    expect(changes, 0);
    expect(container.read(workingSessionsProvider), {'s1'});
  });

  test(
    'a working session that stops being watched stops being counted',
    () async {
      final counts = container.listen(projectWorkingCountsProvider, (_, _) {});
      status('s1', working: true);
      expect(counts.read(), {'p1': 1});

      // It ended, so the server no longer watches it: no status moves, it
      // goes.
      server.attention.forget('s1');
      await Future<void>.delayed(Duration.zero);

      expect(counts.read(), isEmpty);
    },
  );

  test('with nothing working it reads no table', () async {
    container.read(projectWorkingCountsProvider);
    expect(container.exists(sessionProjectIdsProvider), isFalse);
  });
}
