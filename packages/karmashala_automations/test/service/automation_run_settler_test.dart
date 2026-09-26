import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service_fixtures.dart';

void main() {
  late AppDatabase db;
  late AutomationDao dao;
  late AutomationRunSettler settler;
  late List<String> checked;
  late List<String> drained;
  final sessions = <String, Session>{};

  Session session(String id, SessionStatus status) => sessions[id] = Session(
    id: id,
    repositoryId: 'r1',
    agentInstallationId: 'a1',
    title: 'Work',
    useWorktree: false,
    status: status,
    createdAt: fixtureTime,
  );

  setUp(() {
    db = fixtureDatabase();
    dao = AutomationDao(db);
    dao.insert(
      fixtureAutomation(armedAt: fixtureTime).copyWith(stopAfterFailures: 2),
    );
    checked = [];
    drained = [];
    sessions.clear();
    settler = AutomationRunSettler(
      automations: dao,
      sessionOf: (id) => sessions[id],
      runChecks: (run) => checked.add(run.id),
      drain: (repositoryId) async => drained.add(repositoryId),
      now: () => fixtureTime,
    );
  });
  tearDown(() => db.close());

  void running(String runId, String sessionId) => dao.insertRun(
    AutomationRun(
      id: runId,
      automationId: 'auto1',
      scheduledFor: fixtureTime,
      firedAt: fixtureTime,
      state: AutomationRunState.running,
      reason: '',
      sessionId: sessionId,
    ),
  );

  test('a completed session finishes its run, checks it and frees the '
      'queue', () {
    running('run1', 's1');
    settler.settleSession('s1', SessionEnding.completed);
    expect(dao.runById('run1')!.state, AutomationRunState.finished);
    expect(checked, ['run1']);
    expect(drained, ['r1']);
  });

  test('losing sight of a session is not an ending', () {
    running('run1', 's1');
    settler.settleSession('s1', SessionEnding.lostTrack);
    expect(dao.runById('run1')!.state, AutomationRunState.running);
    expect(checked, isEmpty);
  });

  test('the sweep settles what the store says ended, for sessions it '
      'owns', () {
    running('run1', 's1');
    running('run2', 's2');
    session('s1', SessionStatus.failed);
    session('s2', SessionStatus.completed);
    settler.sweep(owns: (s) => s.id == 's1');
    expect(dao.runById('run1')!.state, AutomationRunState.failed);
    expect(dao.runById('run2')!.state, AutomationRunState.running);
  });

  test('a run the person stopped settles as stopped by them and spends no '
      'budget', () {
    running('run1', 's1');
    settler.settleSession('s1', SessionEnding.failed);
    expect(dao.getById('auto1')!.consecutiveFailures, 1);

    running('run2', 's2');
    settler.settleSession('s2', SessionEnding.cancelled);
    final run = dao.runById('run2')!;
    expect(
      run.state,
      AutomationRunSettler.stateOfEnding(SessionEnding.cancelled),
    );
    expect(run.reason, contains('was stopped by you'));
    expect(checked, ['run1', 'run2']);
    final automation = dao.getById('auto1')!;
    expect(
      automation.consecutiveFailures,
      1,
      reason: 'neither spent nor reset',
    );
    expect(automation.enabled, isTrue);
  });

  test('a second ending for a settled run changes nothing and runs no checks '
      'again', () {
    running('run1', 's1');
    settler.settleSession('s1', SessionEnding.cancelled);
    settler.settleSession('s1', SessionEnding.failed);
    expect(dao.runById('run1')!.reason, contains('was stopped by you'));
    expect(checked, ['run1']);
    expect(drained, ['r1']);
    expect(dao.getById('auto1')!.consecutiveFailures, 0);
  });

  test('failures in a row spend the budget and stop the automation', () {
    for (final id in ['run1', 'run2']) {
      running(id, 's-$id');
      settler.settleSession('s-$id', SessionEnding.failed);
    }
    final automation = dao.getById('auto1')!;
    expect(automation.enabled, isFalse);
    expect(automation.disabledReason, contains('2 failed runs in a row'));
  });
}
