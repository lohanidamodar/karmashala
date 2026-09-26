import 'dart:async';

import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:karmashala_session/events.dart';

/// The live half of the signal: what the observer does with a status change in
/// a session whose row still says `running`.
void main() {
  late Override data;
  late FakeFollowUpRows followUps;
  late StreamController<AgentStatusReport> reports;

  AgentStatusReport report(AgentActivityStatus status) => AgentStatusReport(
    agentId: AgentIds.claudeCode,
    sessionId: 's1',
    status: status,
    observedAt: testTime,
    source: AgentStatusSource.terminalGrid,
  );

  setUp(() async {
    final server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    data = await server.override();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation());
    server.sessionRows.insert(session(id: 's1', status: SessionStatus.running));
    followUps = server.followUpRows;
    reports = StreamController<AgentStatusReport>.broadcast();
    addTearDown(reports.close);
  });

  /// Mounts the observer over a status stream this test drives by hand.
  Future<ProviderContainer> observing() async {
    final container = ProviderContainer(
      overrides: [
        data,
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

  Future<void> emit(List<AgentActivityStatus> statuses) async {
    for (final status in statuses) {
      reports.add(report(status));
      // Long enough for a follow-up it raised to be answered by the server.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
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
