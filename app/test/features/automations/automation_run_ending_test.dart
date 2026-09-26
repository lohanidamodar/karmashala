import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_runner.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/pane_exit_signal.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fake_host_lifecycle.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/workspace_mirror.dart';

/// When an automation's session has ended: the recorded row for a hosted one,
/// the pane and live status for one without host facts.
void main() {
  late FakeDataServer server;
  late AppDatabase db;
  late Directory artifacts;
  late StreamController<AgentStatusReport> reports;
  late FakeHostLifecycle host;

  final due = DateTime.utc(2026, 9, 9, 3);

  setUp(() async {
    db = AppDatabase.memory();
    artifacts = Directory.systemTemp.createTempSync('automation-endings');
    server = FakeDataServer()..mirrorInto(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(agentInstallation(agentId: AgentIds.claudeCode));
    AutomationDao(db).insert(
      Automation(
        id: 'auto1',
        repositoryId: 'r1',
        name: 'Nightly sweep',
        schedule: const AutomationSchedule.cron('0 3 * * *'),
        agentInstallationId: 'a1',
        prompt: 'Fix what broke.',
        permissionMode: const PermissionSelection({'mode': 'auto'}),
        enabled: true,
        armedAt: testTime,
      ),
    );
    server.sessionRows.insert(session(status: SessionStatus.running));
    AutomationDao(db).insertRun(
      AutomationRun(
        id: 'run1',
        automationId: 'auto1',
        scheduledFor: due,
        firedAt: testTime,
        state: AutomationRunState.running,
        reason: '',
        sessionId: 's1',
      ),
    );
    reports = StreamController<AgentStatusReport>.broadcast();
    host = FakeHostLifecycle(server)
      ..snapshot = [hostFacts('s1', HostSessionState.running)];
    addTearDown(() async {
      await reports.close();
      db.close();
      if (artifacts.existsSync()) artifacts.deleteSync(recursive: true);
    });
  });

  AutomationRun theRun() => AutomationDao(db).runsFor('auto1').single;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The observer mounted as the app mounts it; [hosted] also watches the host.
  Future<ProviderContainer> observing({required bool hosted}) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('id-')),
        verificationRootProvider.overrideWithValue(artifacts),
        agentSessionStatusProvider.overrideWith((ref, id) => reports.stream),
        hostLifecycleSourceProvider.overrideWithValue(hosted ? host : null),
      ],
    );
    addTearDown(container.dispose);
    container.listen(hostLifecycleSubscriberProvider, (_, _) {});
    container.listen(automationRunObserverProvider, (_, _) {});
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
    test('a pane exiting in a host restart holds the checkout until the '
        'recorder says the session ended', () async {
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
      expect(server.sessionRows.getById('s1')!.status, SessionStatus.unknown);
      paneExits(container, exitCode: 0);
      await settle();
      expect(theRun().state, AutomationRunState.running);

      // The host comes back and the pane starts the session again.
      host.snapshot = [
        hostFacts(
          's1',
          HostSessionState.exited,
          reason: 'host stopped while running',
          second: 3,
        ),
      ];
      container.read(hostLifecycleSubscriberProvider)!.nudge();
      await settle();
      host.link.add(hostEvent('s1', SessionLifecycleKind.started, second: 4));
      await settle();
      expect(theRun().state, AutomationRunState.running);

      host.link.add(
        hostEvent('s1', SessionLifecycleKind.exited, exitCode: 0, second: 5),
      );
      await settle();
      expect(theRun().state, AutomationRunState.finished);
    });

    test('a live failure is not an ending; a recorded exit 1 is', () async {
      final container = await observing(hosted: true);
      await emit([AgentActivityStatus.working, AgentActivityStatus.failed]);
      paneExits(container, exitCode: 1);
      await settle();
      expect(theRun().state, AutomationRunState.running);

      host.link.add(
        hostEvent('s1', SessionLifecycleKind.exited, exitCode: 1, second: 5),
      );
      await settle();
      expect(theRun().state, AutomationRunState.failed);
      expect(theRun().reason, contains('stopped in error'));
    });

    test('closed on request fails the run as stopped by you', () async {
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
      expect(theRun().state, AutomationRunState.failed);
      expect(theRun().reason, contains('was stopped by you'));
    });

    test(
      'an ending recorded while the app was away settles on start',
      () async {
        host.snapshot = [
          hostFacts('s1', HostSessionState.exited, exitCode: 0, second: 5),
        ];
        await observing(hosted: true);
        await settle();
        expect(theRun().state, AutomationRunState.finished);
      },
    );
  });

  group('a session without host facts', () {
    test('a clean pane exit finishes the run', () async {
      final container = await observing(hosted: false);
      paneExits(container, exitCode: 0);
      await settle();
      expect(theRun().state, AutomationRunState.finished);
    });

    test('a live failure fails the run', () async {
      await observing(hosted: false);
      await emit([AgentActivityStatus.working, AgentActivityStatus.failed]);
      expect(theRun().state, AutomationRunState.failed);
    });
  });
}
