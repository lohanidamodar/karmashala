import 'dart:async';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/follow_ups/application/follow_up_providers.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/pane_exit_signal.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../support/fake_host_lifecycle.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';
import '../terminal/fake_instance.dart';
import 'package:karmashala_session/events.dart';

/// A hosted session's follow-up is owed by what the recorder wrote to its row,
/// never by its pane exiting or its live status.
void main() {
  late AppDatabase db;
  late Override data;
  late FakeDataServer server;
  late FakeFollowUpRows followUps;
  late StreamController<AgentStatusReport> reports;
  late FakeHostLifecycle host;

  setUp(() async {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    server = FakeDataServer()..mirrorInto(db);
    data = await server.override();
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    server.sessionRows.insert(session(id: 's1', status: SessionStatus.running));
    // Outstanding verification, so a clean finish is owed a follow-up.
    VerificationDao(db).insertRun(
      VerificationRun(
        id: 'v1',
        title: 'the login page still loads',
        target: const VerificationTarget.browser('https://example.com'),
        startedAt: testTime,
        artifactDirectory: 'C:/art/v1',
        sessionId: 's1',
      ),
    );
    followUps = server.followUpRows;
    reports = StreamController<AgentStatusReport>.broadcast();
    host = FakeHostLifecycle(server)
      ..snapshot = [hostFacts('s1', HostSessionState.running)];
    addTearDown(() async {
      await reports.close();
      db.close();
    });
  });

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<ProviderContainer> observing({required bool hosted}) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        data,
        clockProvider.overrideWithValue(FixedClock(testTime)),
        agentSessionStatusProvider.overrideWith((ref, id) => reports.stream),
        hostLifecycleSourceProvider.overrideWithValue(hosted ? host : null),
      ],
    );
    addTearDown(container.dispose);
    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    container.listen(sessionEndingObserverProvider, (_, _) {});
    await settle();
    return container;
  }

  void paneExits(ProviderContainer container, {required int? exitCode}) =>
      container
          .read(paneExitProvider.notifier)
          .record(
            PaneExit(paneId: 'agent-pane', sessionId: 's1', exitCode: exitCode),
          );

  Future<void> emit(List<AgentActivityStatus> statuses) async {
    for (final status in statuses) {
      reports.add(
        AgentStatusReport(
          agentId: AgentIds.claudeCode,
          sessionId: 's1',
          status: status,
          observedAt: testTime,
          source: AgentStatusSource.terminalGrid,
        ),
      );
      await settle();
    }
  }

  group('a hosted session', () {
    test('a pane exiting in a host restart raises nothing until the recorder '
        'says the session finished', () async {
      final container = await observing(hosted: true);

      host.link.add(
        hostEvent(
          's1',
          SessionLifecycleKind.exited,
          reason: 'host stopped while running',
          second: 2,
        ),
      );
      await host.link.close();
      await settle();
      paneExits(container, exitCode: 0);
      await settle();
      expect(followUps.open(), isEmpty);

      host.snapshot = [hostFacts('s1', HostSessionState.running, second: 3)];
      container.read(hostLifecycleSubscriberProvider)!.nudge();
      await settle();
      host.link.add(
        hostEvent('s1', SessionLifecycleKind.exited, exitCode: 0, second: 5),
      );
      await settle();

      final raised = followUps.open().single;
      expect(raised.ending, SessionEnding.completed);
      expect(raised.reason, FollowUpReason.verificationAbandoned);
    });

    test('a live failure raises nothing; a recorded exit 1 does', () async {
      await observing(hosted: true);
      await emit([AgentActivityStatus.working, AgentActivityStatus.failed]);
      expect(followUps.open(), isEmpty);

      host.link.add(
        hostEvent('s1', SessionLifecycleKind.exited, exitCode: 1, second: 5),
      );
      await settle();

      final raised = followUps.open().single;
      expect(raised.ending, SessionEnding.failed);
      expect(raised.reason, FollowUpReason.endedInFailure);
    });

    test('closed on request is cancelled, which is owed nothing', () async {
      await observing(hosted: true);
      host.link.add(
        hostEvent(
          's1',
          SessionLifecycleKind.closed,
          endedByClose: true,
          second: 5,
        ),
      );
      await settle();
      expect(server.sessionRows.getById('s1')!.status, SessionStatus.cancelled);
      expect(followUps.open(), isEmpty);
    });
  });

  group('a session without host facts', () {
    test('a clean pane exit is still a finish', () async {
      final container = await observing(hosted: false);
      paneExits(container, exitCode: 0);
      await settle();
      expect(followUps.open().single.ending, SessionEnding.completed);
    });

    test('a live failure is still noticed', () async {
      await observing(hosted: false);
      await emit([AgentActivityStatus.working, AgentActivityStatus.failed]);
      expect(followUps.open().single.reason, FollowUpReason.endedInFailure);
    });
  });
}
