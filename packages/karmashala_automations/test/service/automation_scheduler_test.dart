import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service_fixtures.dart';

class _RecordingFiring implements AutomationFiring {
  _RecordingFiring(this.dao, this.now);
  final AutomationDao dao;
  final DateTime Function() now;
  final fired = <({String id, DateTime due, String? queuedId})>[];
  var next = 0;

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async {
    fired.add((id: automation.id, due: scheduledFor, queuedId: queued?.id));
    final run =
        (queued ??
                AutomationRun(
                  id: 'fired-${next++}',
                  automationId: automation.id,
                  scheduledFor: scheduledFor,
                  firedAt: now(),
                  state: AutomationRunState.running,
                  reason: note,
                ))
            .copyWith(state: AutomationRunState.running);
    queued == null ? dao.insertRun(run) : dao.updateRun(run);
  }
}

class _NoResumes implements ScheduledResumeFiring {
  final fired = <String>[];
  @override
  Future<void> fire(ScheduledResume resume, {String note = ''}) async =>
      fired.add(resume.id);
}

class _Chore implements SchedulerChore {
  DateTime? due;
  var started = 0;
  @override
  DateTime? nextDue({required DateTime availableSince}) => due;
  @override
  void startIfDue(DateTime now, {required DateTime availableSince}) {
    if (due != null && !due!.isAfter(now)) started++;
  }
}

void main() {
  // A 03:00 cron occurrence, in the machine's own zone.
  final due = DateTime(2026, 9, 25, 3);
  late AppDatabase db;
  late AutomationDao dao;
  late DateTime now;
  late ManualAutomationTimer timer;
  late _RecordingFiring firing;
  late _Chore chore;
  var ids = 0;

  AutomationScheduler scheduler({bool firesAutomations = true}) =>
      AutomationScheduler(
        automations: dao,
        resumes: ScheduledResumeDao(db),
        sessionOf: (_) => null,
        firing: firing,
        resumeFiring: _NoResumes(),
        timer: timer,
        now: () => now,
        newId: () => 'id-${++ids}',
        chores: [chore],
        firesAutomations: firesAutomations,
      );

  setUp(() {
    db = fixtureDatabase();
    dao = AutomationDao(db);
    timer = ManualAutomationTimer();
    firing = _RecordingFiring(dao, () => now);
    chore = _Chore();
    dao.insert(
      fixtureAutomation(
        armedAt: due.subtract(const Duration(hours: 1)).toUtc(),
      ),
    );
  });
  tearDown(() => db.close());

  group('the missed-run rule, applied when the scheduler starts', () {
    test('inside the grace the occurrence fires once', () async {
      now = due.add(const Duration(minutes: 10)).toUtc();
      await scheduler().start();
      expect(firing.fired.single.due, due.toUtc());
      await scheduler().reconcile();
      expect(firing.fired, hasLength(1));
    });

    test('beyond the grace it is a missed row with its reason', () async {
      now = due.add(kMissedFireGrace + const Duration(minutes: 1)).toUtc();
      await scheduler().start();
      expect(firing.fired, isEmpty);
      final missed = dao.runsFor('auto1').single;
      expect(missed.state, AutomationRunState.missed);
      expect(missed.scheduledFor, due.toUtc());
      expect(missed.reason, contains('was not running'));
    });

    test('"skip" never catches up an occurrence it was down for', () async {
      dao.update(
        fixtureAutomation(
          armedAt: due.subtract(const Duration(hours: 1)).toUtc(),
          latePolicy: AutomationLatePolicy.skip,
        ),
      );
      now = due.add(const Duration(minutes: 5)).toUtc();
      await scheduler().start();
      expect(firing.fired, isEmpty);
      expect(dao.runsFor('auto1').single.state, AutomationRunState.missed);
    });

    test('"run" catches up however late', () async {
      dao.update(
        fixtureAutomation(
          armedAt: due.subtract(const Duration(hours: 1)).toUtc(),
          latePolicy: AutomationLatePolicy.run,
        ),
      );
      now = due.add(const Duration(hours: 5)).toUtc();
      await scheduler().start();
      expect(firing.fired.single.due, due.toUtc());
    });
  });

  test(
    'a run another process queued starts once its checkout is free',
    () async {
      now = due.subtract(const Duration(hours: 2)).toUtc();
      dao.insertRun(
        AutomationRun(
          id: 'queued-by-the-app',
          automationId: 'auto1',
          scheduledFor: now,
          firedAt: now,
          state: AutomationRunState.queued,
          reason: 'Because "Work" finishes a turn.',
          eventSessionId: 's1',
        ),
      );
      await scheduler().reconcile();
      expect(firing.fired.single.queuedId, 'queued-by-the-app');
    },
  );

  test('where another process fires automations, only chores ride the '
      'timer', () async {
    now = due.add(const Duration(minutes: 5)).toUtc();
    chore.due = now.add(const Duration(minutes: 30));
    final chores = scheduler(firesAutomations: false);
    await chores.start();
    expect(firing.fired, isEmpty);
    expect(dao.runsFor('auto1'), isEmpty);
    expect(timer.armedFor, const Duration(minutes: 30));
    now = chore.due!;
    await chores.reconcile();
    expect(chore.started, 1);
  });

  test('a stopped scheduler arms nothing and fires nothing', () async {
    now = due.add(const Duration(minutes: 5)).toUtc();
    final stopped = scheduler()..stop();
    await stopped.reconcile();
    stopped.arm();
    expect(firing.fired, isEmpty);
    expect(timer.isArmed, isFalse);
  });
}
