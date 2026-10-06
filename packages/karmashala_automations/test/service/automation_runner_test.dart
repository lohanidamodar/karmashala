import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_automations/store.dart';
import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service_fixtures.dart';

class _Checkpoints implements RunBaseCheckpoint {
  Object? failWith;
  @override
  Future<String?> capture(
    EnvironmentPath checkout, {
    required String runId,
    required String label,
  }) async {
    if (failWith != null) throw failWith!;
    return 'base-of-$runId';
  }
}

class _Launcher implements AutomationSessionLauncher {
  Object? failWith;
  final launched = <String>[];
  @override
  Future<String> launch(
    Automation automation,
    Repository repository,
    AgentInstallation installation,
  ) async {
    if (failWith != null) throw failWith!;
    launched.add(automation.id);
    return 'session-1';
  }
}

void main() {
  late AppDatabase db;
  late AutomationDao dao;
  late FakeCheckoutFacts facts;
  late _Checkpoints checkpoints;
  late _Launcher launcher;
  late AutomationRunner runner;
  var ids = 0;

  final unattended = PermissionSelection.parse(
    'approval=never;sandbox=danger-full-access',
  );

  setUp(() {
    db = fixtureDatabase();
    dao = AutomationDao(db);
    ProjectCheckDao(db)
      ..setVerificationEnabled('r1', enabled: true, now: fixtureTime)
      ..insert(
        ProjectCheck(
          id: 'c1',
          repositoryId: 'r1',
          name: 'tests',
          command: const ['make', 'test'],
          createdAt: fixtureTime,
        ),
      );
    facts = FakeCheckoutFacts();
    checkpoints = _Checkpoints();
    launcher = _Launcher();
    runner = AutomationRunner(
      automations: dao,
      preflight: UnattendedPreflight(facts: facts, checks: ProjectCheckDao(db)),
      facts: facts,
      checkpoints: checkpoints,
      launcher: launcher,
      now: () => fixtureTime,
      newId: () => 'run-${++ids}',
    );
  });
  tearDown(() => db.close());

  Automation automation() => fixtureAutomation(
    armedAt: fixtureTime,
  ).copyWith(permissionMode: unattended);

  test('a fire records its base, then the session it started', () async {
    await runner.fire(automation(), fixtureTime);
    final run = dao.runsFor('auto1').single;
    expect(run.state, AutomationRunState.running);
    expect(run.baseCheckpointId, 'base-of-${run.id}');
    expect(run.sessionId, 'session-1');
  });

  test('a queued row becomes the run, not a second row beside it', () async {
    final queued = AutomationRun(
      id: 'waiting',
      automationId: 'auto1',
      scheduledFor: fixtureTime,
      firedAt: fixtureTime,
      state: AutomationRunState.queued,
      reason: 'busy',
    );
    dao.insertRun(queued);
    await runner.fire(automation(), fixtureTime, queued: queued, note: 'go');
    final run = dao.runsFor('auto1').single;
    expect(run.id, 'waiting');
    expect(run.reason, 'go');
    expect(run.sessionId, 'session-1');
  });

  test('the gate refusing is a failed run in its words', () async {
    facts.reachable = UnattendedReach.unreachable;
    await runner.fire(automation(), fixtureTime);
    final run = dao.runsFor('auto1').single;
    expect(run.state, AutomationRunState.failed);
    expect(run.reason, isNotEmpty);
    expect(launcher.launched, isEmpty);
  });

  test('no base, no run: there would be nothing to undo it with', () async {
    checkpoints.failWith = StateError('index locked');
    await runner.fire(automation(), fixtureTime);
    final run = dao.runsFor('auto1').single;
    expect(run.state, AutomationRunState.failed);
    expect(run.reason, contains('nothing to undo it with'));
    expect(launcher.launched, isEmpty);
  });

  test('a launch that fails fails the run with its reason', () async {
    launcher.failWith = StateError('no such executable');
    await runner.fire(automation(), fixtureTime);
    final run = dao.runsFor('auto1').single;
    expect(run.state, AutomationRunState.failed);
    expect(run.reason, contains('no such executable'));
  });

  test('start answers the run it made, with its session', () async {
    final run = await runner.start(automation(), fixtureTime, note: 'call');
    expect(run.id, dao.runsFor('auto1').single.id);
    expect(run.sessionId, 'session-1');
    expect(run.state, AutomationRunState.running);
    expect(run.reason, 'call');
  });

  test('start answers a refused run too, never a session', () async {
    facts.reachable = UnattendedReach.unreachable;
    final run = await runner.start(automation(), fixtureTime);
    expect(run.state, AutomationRunState.failed);
    expect(run.sessionId, isNull);
  });
}
