import 'dart:async';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_runner.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/pane_exit_signal.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/karmashala_session_engine.dart';

import '../../support/fake_host_lifecycle.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// When the session of a run on an SSH box has ended, by its pane and live
/// status — the runs this app settles. The server settles its own machine's
/// (`server/test/automations/daemon_automations_test.dart`); the settling
/// rules are `karmashala_automations`'.
void main() {
  late FakeDataServer server;
  late Directory artifacts;
  late StreamController<AgentStatusReport> reports;
  late FakeHostLifecycle host;

  final due = DateTime.utc(2026, 9, 9, 3);

  setUp(() async {
    artifacts = Directory.systemTemp.createTempSync('automation-endings');
    server = FakeDataServer();
    // On an SSH box: the one kind of run this app settles itself.
    server.environmentRows.upsert(windowsEnv());
    server.environmentRows.upsert(sshEnvFixture());
    server.projectRows.insert(project(environmentId: 'ssh:h1', path: '/src'));
    server.repositoryRows.insert(
      repository(environmentId: 'ssh:h1', path: '/src/app'),
    );
    server.installationRows.insert(
      agentInstallation(
        agentId: AgentIds.claudeCode,
        environmentId: 'ssh:h1',
        path: '/usr/bin/claude',
      ),
    );
    server.automationRows.insert(
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
    server.automationRows.insertRun(
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
      if (artifacts.existsSync()) artifacts.deleteSync(recursive: true);
    });
  });

  AutomationRun theRun() => server.automationRows.runsFor('auto1').single;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The observer mounted as the app mounts it; [hosted] also watches the host.
  Future<ProviderContainer> observing({required bool hosted}) async {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
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

  group('a session without host facts', () {
    test('a clean pane exit finishes the run', () async {
      final container = await observing(hosted: false);
      paneExits(container, exitCode: 0);
      await settle();
      await container.read(dataClientProvider).settled();
      expect(theRun().state, AutomationRunState.finished);
    });

    test('a live failure fails the run', () async {
      final container = await observing(hosted: false);
      await emit([AgentActivityStatus.working, AgentActivityStatus.failed]);
      await container.read(dataClientProvider).settled();
      expect(theRun().state, AutomationRunState.failed);
    });
  });
}
