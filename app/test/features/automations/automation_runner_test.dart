import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_runner.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/checks.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Records the launch request and starts nothing.
class _FakeLauncher extends SessionLauncher {
  _FakeLauncher(super.ref);

  final List<SessionLaunchRequest> requests = [];

  @override
  Future<SessionLaunchResult> launch(
    SessionLaunchRequest request, {
    SystemTerminal? externalTerminal,
  }) async {
    requests.add(request);
    return SessionLaunchResult(session: session(id: 'started'));
  }
}

/// This app fires an automation only where the server forwards it (a WSL or
/// SSH checkout): its base taken by the server's checkpoint recorder, its
/// launcher, the gate read from its copies, and every row recorded at the
/// server. The runner's
/// rules are tested in `karmashala_automations`.
void main() {
  late FakeDataServer server;
  late ProviderContainer container;
  late _FakeLauncher launcher;
  final due = DateTime.utc(2026, 9, 9, 3);

  Automation automation({PermissionSelection? mode}) => Automation(
    id: 'auto1',
    repositoryId: 'r1',
    name: 'Nightly sweep',
    schedule: const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: 'a1',
    prompt: 'Run the checks and fix what broke.',
    permissionMode: mode ?? const PermissionSelection({'mode': 'auto'}),
    enabled: true,
    armedAt: testTime,
  );

  Future<AutomationRun> theRun() async {
    await container.read(dataClientProvider).settled();
    return server.automationRows.runsFor('auto1').single;
  }

  setUp(() async {
    server = FakeDataServer()
      ..environmentRows.upsert(windowsEnv())
      ..projectRows.insert(project())
      ..repositoryRows.insert(repository())
      ..installationRows.insert(agentInstallation(agentId: AgentIds.claudeCode))
      ..automationRows.insert(automation())
      ..projectCheckRows.setVerificationEnabled('r1', enabled: true)
      ..projectCheckRows.insert(
        ProjectCheck(
          id: 'c1',
          repositoryId: 'r1',
          name: 'the test suite',
          command: const ['flutter', 'test'],
          createdAt: testTime,
        ),
      );
    server.checkpointWork.nextCapture = Checkpoint(
      id: 'cp1',
      sessionId: 'run-1',
      repository: const EnvironmentPath(
        environmentId: 'windows',
        path: r'C:\src\demo',
      ),
      sequence: 1,
      treeSha: 'tree',
      commitSha: 'commit',
      parentCommitSha: null,
      headSha: 'head',
      reason: CheckpointReason.manual,
      createdAt: testTime,
    );
    container = ProviderContainer(
      overrides: [
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('run-')),
        sessionLauncherProvider.overrideWith(_FakeLauncher.new),
      ],
    );
    launcher = container.read(sessionLauncherProvider) as _FakeLauncher;
    addTearDown(container.dispose);
  });

  AutomationRunner runner() => container.read(automationRunnerProvider);

  test('a fire records its base and its session at the server', () async {
    await runner().fire(automation(), due);
    final run = await theRun();
    expect(run.state, AutomationRunState.running);
    expect(run.sessionId, 'started');
    expect(run.baseCheckpointId, 'cp1');
    final capture = server.checkpointWork.asked.single as CheckpointCaptureBase;
    expect(capture.runId, run.id);
    expect(capture.checkout, repository().path);
    final request = launcher.requests.single;
    expect(request.firstMessage, 'Run the checks and fix what broke.');
    expect(request.purpose, SessionPurpose.newSession);
    expect(request.permissionOverride?.canonical, 'mode=auto');
  });

  test(
    'a mode that would prompt is refused at fire time, and recorded',
    () async {
      await runner().fire(
        automation(mode: const PermissionSelection({'mode': 'manual'})),
        due,
      );
      final run = await theRun();
      expect(run.state, AutomationRunState.failed);
      expect(run.reason, contains('nobody there to answer'));
      expect(launcher.requests, isEmpty);
    },
  );

  test('a queued entry the server drained becomes the run', () async {
    final waiting = AutomationRun(
      id: 'waiting',
      automationId: 'auto1',
      scheduledFor: due,
      firedAt: testTime,
      state: AutomationRunState.queued,
      reason: 'This checkout is busy.',
    );
    server.automationRows.insertRun(waiting);
    await runner().fire(
      automation(),
      due,
      note: 'started when it came free',
      queued: waiting,
    );
    final run = await theRun();
    expect(run.id, 'waiting');
    expect(run.state, AutomationRunState.running);
    expect(run.reason, 'started when it came free');
  });
}
