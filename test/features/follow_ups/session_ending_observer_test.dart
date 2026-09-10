import 'dart:async';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala/src/features/follow_ups/data/follow_up_dao.dart';
import 'package:karmashala/src/features/follow_ups/domain/follow_up.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The live half of the signal: what the observer does with a status change in
/// a session whose row still says `running`.
void main() {
  late AppDatabase db;
  late FollowUpDao followUps;
  late StreamController<AgentStatusReport> reports;

  AgentStatusReport report(AgentActivityStatus status) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 's1',
    status: status,
    observedAt: testTime,
    source: AgentStatusSource.terminalGrid,
  );

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    SessionDao(db).insert(session(id: 's1', status: SessionStatus.running));
    followUps = FollowUpDao(db);
    reports = StreamController<AgentStatusReport>.broadcast();
    addTearDown(reports.close);
  });
  tearDown(() => db.close());

  /// Mounts the observer over a status stream this test drives by hand.
  Future<ProviderContainer> observing() async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentSessionStatusProvider.overrideWith((ref, id) => reports.stream),
      ],
    );
    addTearDown(container.dispose);
    // Watched, not merely read: Riverpod 3 pauses a provider's own
    // subscriptions while nothing listens to it, so an observer nobody watches
    // sees nothing. The app mounts it the same way, through `openFollowUps`.
    container.listen(sessionEndingObserverProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    return container;
  }

  Future<void> emit(
    List<AgentActivityStatus> statuses,
  ) async {
    for (final status in statuses) {
      reports.add(report(status));
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a crash mid-session is noticed', () async {
    await observing();
    await emit([AgentActivityStatus.working, AgentActivityStatus.failed]);
    expect(followUps.open().single.reason, FollowUpReason.endedInFailure);
  });

  test('the first thing we ever see is not a change', () async {
    // Every live session reports for the first time on app start. Reading that
    // as a crash would open the app on a notice for every session that broke
    // last week — the same rule `AgentStatusTransition` states.
    await observing();
    await emit([AgentActivityStatus.failed]);
    expect(followUps.open(), isEmpty);
  });

  test('a turn ending is not a session ending', () async {
    // working -> idle happens many times in one session and is exactly what the
    // attention inbox already reports as "finished".
    await observing();
    await emit([
      AgentActivityStatus.working,
      AgentActivityStatus.idle,
      AgentActivityStatus.working,
      AgentActivityStatus.idle,
    ]);
    expect(followUps.open(), isEmpty);
  });

  test('losing sight of a session raises nothing', () async {
    await observing();
    await emit([AgentActivityStatus.working, AgentActivityStatus.unknown]);
    expect(followUps.open(), isEmpty);
  });

  test('a session that keeps reporting failure is noticed once', () async {
    await observing();
    await emit([
      AgentActivityStatus.working,
      AgentActivityStatus.failed,
      AgentActivityStatus.failed,
      AgentActivityStatus.working,
      AgentActivityStatus.failed,
    ]);
    expect(followUps.open(), hasLength(1));
  });

  test('an approval is not an ending', () async {
    await observing();
    await emit([
      AgentActivityStatus.working,
      AgentActivityStatus.awaitingApproval,
    ]);
    expect(followUps.open(), isEmpty);
  });
}
