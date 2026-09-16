import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/automations/application/automation_check_runner.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_runner.dart';
import 'package:karmashala/src/features/automations/data/automation_dao.dart';
import 'package:karmashala/src/features/automations/domain/automation.dart';
import 'package:karmashala/src/features/automations/domain/automation_check_verdict.dart';
import 'package:karmashala/src/features/automations/domain/automation_run.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala/src/features/terminal/application/pane_exit_signal.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/verification/application/verification_providers.dart';
import 'package:karmashala/src/features/verification/data/verification_dao.dart';
import 'package:karmashala/src/features/verification/domain/verification_run.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';

/// The checks a checkout says must still pass, run after the automation's
/// session ends — and never reported as a pass unless one was observed.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late Directory artifacts;

  final due = DateTime.utc(2026, 9, 9, 3);

  Automation automation() => Automation(
    id: 'auto1',
    repositoryId: 'r1',
    name: 'Nightly sweep',
    schedule: const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: 'a1',
    prompt: 'Fix what broke.',
    permissionMode: const PermissionSelection({'mode': 'auto'}),
    enabled: true,
    armedAt: testTime,
  );

  AutomationRun theRun() => AutomationDao(db).runsFor('auto1').single;
  List<AutomationCheckVerdict> verdicts() =>
      AutomationDao(db).checksFor(theRun().id);

  void addCheck(String name, List<String> command) => container
      .read(automationControllerProvider)
      .addCheck('r1', name, command);

  int tabCount() =>
      container.read(terminalSessionsControllerProvider).tabs.length;

  /// The pane the sequence has just opened — the newest tab in the window.
  String newestPane() =>
      container.read(terminalSessionsControllerProvider).tabs.last.focusedPaneId;

  /// Runs the event queue until [ready] holds, or gives up.
  ///
  /// A verdict lands one artifact directory after its pane's exit, so a test
  /// that reads it back has to let that write happen — the same thing
  /// `VerificationRecorder.drain` exists for on the other side.
  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await pumpEventQueue();
    }
  }

  /// The agent's own session finishing, which is what sets the checks off.
  Future<void> endTheAgentsSession({bool opensPane = true}) async {
    container
        .read(paneExitProvider.notifier)
        .record(const PaneExit(paneId: 'agent-pane', sessionId: 's1', exitCode: 0));
    await until(() => opensPane ? tabCount() > 0 : theRun().checksObservedAt != null);
  }

  /// The pane a check is running in stopping, with the code it stopped on.
  Future<void> endCheckPane({required int? exitCode}) async {
    final before = verdicts().length;
    container
        .read(paneExitProvider.notifier)
        .record(PaneExit(paneId: newestPane(), sessionId: null, exitCode: exitCode));
    await until(() => verdicts().length > before);
  }

  setUp(() {
    db = AppDatabase.memory();
    artifacts = Directory.systemTemp.createTempSync('automation-checks');
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    AutomationDao(db).insert(automation());
    SessionDao(db).insert(session(status: SessionStatus.running));
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
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('id-')),
        verificationRootProvider.overrideWithValue(artifacts),
      ],
    );
    // Watched, not read — the observer's subscriptions are paused otherwise,
    // which is the failure its own doc warns about.
    container.listen(automationRunObserverProvider, (_, _) {});
    addTearDown(() {
      container.dispose();
      db.close();
      if (artifacts.existsSync()) artifacts.deleteSync(recursive: true);
    });
  });

  test('two checks yield two verdicts, in the checkout\'s own order', () async {
    addCheck('the test suite', const ['flutter', 'test']);
    addCheck('analyze', const ['flutter', 'analyze']);

    await endTheAgentsSession();
    // One pane at a time: the second check does not start until the first has
    // stopped, so the order on the row is the order they ran in.
    expect(tabCount(), 1);
    await endCheckPane(exitCode: 0);
    await until(() => tabCount() > 1);
    await endCheckPane(exitCode: 2);
    await container.read(automationCheckRunnerProvider).drain();

    final recorded = verdicts();
    expect(recorded.map((v) => v.name), ['the test suite', 'analyze']);
    expect(recorded.map((v) => v.ordinal), [1, 2]);
    expect(recorded.first.verdict, VerificationVerdict.pass);
    expect(recorded.last.verdict, VerificationVerdict.fail);
    expect(recorded.last.reason, contains('exited 2'));
    // Every reading carries its age (§19).
    expect(recorded.every((v) => v.checkedAt == testTime), isTrue);
    expect(theRun().checksObservedAt, testTime);
  });

  test('the command runs in the repository\'s own environment, visibly',
      () async {
    addCheck('the test suite', const ['flutter', 'test']);
    await endTheAgentsSession();

    final terminals = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    final launch =
        (terminals.instanceFor(newestPane()) as FakeTerminalInstance)
            .agentLaunch!;
    expect(launch.executable, 'flutter');
    expect(launch.arguments, ['test']);
    expect(launch.workingDirectory, r'C:\src\demo\app');
    expect(launch.agentId, kProjectCheckAgentId);
  });

  test('a check with no exit code is inconclusive, never a pass', () async {
    addCheck('the test suite', const ['flutter', 'test']);
    await endTheAgentsSession();
    await endCheckPane(exitCode: null);
    await container.read(automationCheckRunnerProvider).drain();

    final verdict = verdicts().single;
    expect(verdict.verdict, VerificationVerdict.inconclusive);
    expect(verdict.reason, contains('unknown'));
    expect(theRun().checksObservedAt, testTime);
  });

  test('a run with no checks records that none ran, never that they passed',
      () async {
    await endTheAgentsSession(opensPane: false);
    await container.read(automationCheckRunnerProvider).drain();

    expect(verdicts(), isEmpty);
    // Observed and empty is not the same fact as never looked at.
    expect(theRun().checksObservedAt, testTime);
    final line = describeAutomationChecks(
      verdicts(),
      observedAt: theRun().checksObservedAt,
    );
    expect(line, contains('No project check is configured'));
    expect(line, isNot(contains('passed')));
    expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
  });

  test('a run nobody has checked yet says so, rather than nothing', () {
    expect(theRun().checksObservedAt, isNull);
    expect(
      describeAutomationChecks(const [], observedAt: null),
      contains('have not been run'),
    );
  });

  test('the verdict is the one the verification record kept', () async {
    addCheck('the test suite', const ['flutter', 'test']);
    await endTheAgentsSession();
    await endCheckPane(exitCode: 0);
    await container.read(automationCheckRunnerProvider).drain();

    final verdict = verdicts().single;
    final recorded = VerificationDao(db).getRun(verdict.verificationRunId!)!;
    expect(recorded.verdict, verdict.verdict);
    expect(recorded.steps.single.summary, 'flutter test');
  });

  test('a checkout whose environment cannot be reached is still a worded '
      'verdict', () async {
    addCheck('the test suite', const ['flutter', 'test']);
    // A WSL row that no longer carries the distribution it is for: nothing can
    // say where this checkout's commands would run.
    ExecutionEnvironmentDao(db).upsert(
      ExecutionEnvironment(
        id: 'wsl:gone',
        kind: EnvironmentKind.wsl,
        name: 'gone',
        createdAt: testTime,
      ),
    );
    db.execute("UPDATE repositories SET environment_id = 'wsl:gone';");
    await endTheAgentsSession(opensPane: false);
    await container.read(automationCheckRunnerProvider).drain();

    final verdict = verdicts().single;
    expect(verdict.verdict, VerificationVerdict.inconclusive);
    expect(verdict.reason, contains('did not run'));
    expect(verdict.verificationRunId, isNull);
    expect(container.read(terminalSessionsControllerProvider).tabs, isEmpty);
  });
}
