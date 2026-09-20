import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/application/automation_scheduler.dart';
import 'package:karmashala/src/features/automations/application/automation_timer.dart';
import 'package:karmashala/src/features/automations/data/automation_dao.dart';
import 'package:karmashala/src/features/automations/domain/automation.dart';
import 'package:karmashala/src/features/automations/domain/automation_run.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// A clock a test moves by hand. **Count work, never time it**: nothing here
/// waits for a millisecond, and every "later" is an assignment.
class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// Records what the scheduler asked to be started, and starts nothing.
///
/// It keeps the seam's contract — every fire records a run for its occurrence
/// — because the scheduler's floor is the newest occurrence it has a row for,
/// and a firing that recorded nothing would be found due again forever.
class _RecordingFiring implements AutomationFiring {
  _RecordingFiring(this._dao, this._clock);

  final AutomationDao _dao;
  final _MovableClock _clock;
  final List<({String automationId, DateTime scheduledFor, String note})>
  fired = [];

  /// What the recorded run is left in. `running` is the real runner's answer
  /// once a session is up.
  AutomationRunState settleAs = AutomationRunState.running;

  var _next = 0;

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async {
    fired.add((
      automationId: automation.id,
      scheduledFor: scheduledFor,
      note: note,
    ));
    if (queued != null) {
      _dao.updateRun(queued.copyWith(state: settleAs, reason: note));
      return;
    }
    _dao.insertRun(
      AutomationRun(
        id: 'fired-${_next++}',
        automationId: automation.id,
        scheduledFor: scheduledFor,
        firedAt: _clock.nowUtc(),
        state: settleAs,
        reason: note,
      ),
    );
  }
}

void main() {
  late AppDatabase db;
  late AutomationDao dao;
  late _MovableClock clock;
  late ManualAutomationTimer timer;
  late _RecordingFiring firing;
  late ProviderContainer container;

  // Local time, because a cron expression is written in the machine's own.
  DateTime at(int y, int m, int d, [int h = 0, int min = 0]) =>
      DateTime(y, m, d, h, min);

  Automation nightly({
    String id = 'auto1',
    String name = 'Nightly sweep',
    String repositoryId = 'r1',
    AutomationSchedule? schedule,
    bool enabled = true,
    DateTime? armedAt,
  }) => Automation(
    id: id,
    repositoryId: repositoryId,
    name: name,
    schedule: schedule ?? const AutomationSchedule.cron('0 3 * * *'),
    agentInstallationId: 'a1',
    prompt: 'Run the checks.',
    permissionMode: null,
    enabled: enabled,
    armedAt: armedAt ?? at(2026, 9, 8, 17),
  );

  /// The scheduler, **watched** rather than read.
  ///
  /// Riverpod 3 disposes a provider nobody listens to, and this one cancels its
  /// timer on dispose — so a test that merely read it would watch a scheduler
  /// that had already disarmed itself. That is the same hazard `AppShell`'s
  /// `ref.watch` exists for, reproduced here rather than worked around.
  AutomationScheduler scheduler() {
    container.listen(automationSchedulerProvider, (_, _) {});
    return container.read(automationSchedulerProvider.notifier);
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    RepositoryDao(db).insert(repository(id: 'r2', name: 'other'));
    dao = AutomationDao(db);
    clock = _MovableClock(at(2026, 9, 8, 17));
    timer = ManualAutomationTimer();
    firing = _RecordingFiring(dao, clock);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator('run-')),
        automationTimerProvider.overrideWithValue(timer),
        automationFiringProvider.overrideWithValue(firing),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
  });

  group('one armed timer, not a sweep', () {
    test('nothing scheduled arms nothing at all', () {
      scheduler();
      expect(timer.isArmed, isFalse);
      expect(timer.arms, 0);
    });

    test(
      'the timer is armed for the soonest occurrence across all of them',
      () {
        dao.insert(
          nightly(
            id: 'a',
            schedule: const AutomationSchedule.cron('0 5 * * *'),
          ),
        );
        dao.insert(
          nightly(
            id: 'b',
            schedule: const AutomationSchedule.cron('0 3 * * *'),
          ),
        );
        scheduler();
        // 17:00 to 03:00 is ten hours; the 05:00 one is not what it waits for.
        expect(timer.armedFor, const Duration(hours: 10));
        expect(timer.arms, 1, reason: 'one timer, not one per automation');
      },
    );

    test('a paused automation is not waited for', () {
      dao.insert(nightly(enabled: false));
      scheduler();
      expect(timer.isArmed, isFalse);
    });

    test(
      'a long wait is capped and re-armed rather than held as one timer',
      () {
        dao.insert(
          nightly(schedule: AutomationSchedule.once(at(2027, 1, 1, 3))),
        );
        scheduler();
        expect(timer.armedFor, kMaxTimerDelay);
      },
    );

    test(
      'a change re-arms; nothing asks again on a cadence of its own',
      () async {
        dao.insert(nightly());
        scheduler();
        expect(timer.arms, 1);
        container
            .read(automationControllerProvider)
            .save(
              nightly(schedule: const AutomationSchedule.cron('0 1 * * *')),
            );
        // Riverpod disarms on invalidation and re-arms on the rebuild a
        // microtask later; the gap is the whole of the "poll" this does not do.
        await Future<void>.delayed(Duration.zero);
        // 17:00 to 01:00 is eight hours.
        expect(timer.armedFor, const Duration(hours: 8));
        expect(timer.arms, greaterThan(1));
      },
    );

    test(
      'the timer re-arms after it fires, even when it found nothing',
      () async {
        dao.insert(nightly());
        scheduler();
        final armsBefore = timer.arms;
        timer.fire();
        await Future<void>.delayed(Duration.zero);
        // A tick that found nothing to do writes nothing, so nothing else would
        // have re-armed it. A timer that fired and did not re-arm is a scheduler
        // that has quietly stopped.
        expect(timer.arms, greaterThan(armsBefore));
        expect(timer.isArmed, isTrue);
      },
    );
  });

  group('what reconcile does about a laptop that was shut', () {
    test('no miss: nothing was due, and nothing is recorded', () async {
      dao.insert(nightly(armedAt: at(2026, 9, 9, 4)));
      clock.now = at(2026, 9, 9, 9);
      await scheduler().reconcile();
      expect(firing.fired, isEmpty);
      expect(dao.runsFor('auto1'), isEmpty);
    });

    test('one miss inside the grace window is run, once', () async {
      dao.insert(nightly());
      clock.now = at(2026, 9, 9, 3, 10);
      await scheduler().reconcile();
      expect(firing.fired.single.scheduledFor, at(2026, 9, 9, 3).toUtc());
      expect(firing.fired.single.note, isEmpty, reason: 'only one was missed');
      expect(dao.runsFor('auto1').single.state, AutomationRunState.running);
    });

    test('one miss outside it is a missed row that says why', () async {
      dao.insert(nightly());
      clock.now = at(2026, 9, 9, 9);
      await scheduler().reconcile();
      expect(firing.fired, isEmpty);
      final run = dao.runsFor('auto1').single;
      expect(run.state, AutomationRunState.missed);
      expect(run.scheduledFor, at(2026, 9, 9, 3).toUtc());
      expect(run.reason, contains('6 hours ago'));
      expect(run.reason, isNotEmpty);
    });

    test(
      'several: one catch-up run, and everything older recorded as missed',
      () async {
        dao.insert(
          nightly(schedule: const AutomationSchedule.cron('0 * * * *')),
        );
        clock.now = at(2026, 9, 9, 9, 5);
        await scheduler().reconcile();
        // At most one catch-up run, for the newest occurrence only.
        expect(firing.fired, hasLength(1));
        expect(firing.fired.single.scheduledFor, at(2026, 9, 9, 9).toUtc());
        expect(firing.fired.single.note, contains('16 runs'));
        final missed = dao
            .runsFor('auto1')
            .where((r) => r.state == AutomationRunState.missed)
            .toList();
        expect(missed, hasLength(1));
        expect(missed.single.reason, contains('15 runs'));
      },
    );

    test(
      'a second reconcile does not fire the same occurrence again',
      () async {
        dao.insert(nightly());
        clock.now = at(2026, 9, 9, 3, 10);
        await scheduler().reconcile();
        await scheduler().reconcile();
        expect(firing.fired, hasLength(1));
      },
    );

    test('a one-shot that was missed is over, not left armed', () async {
      dao.insert(nightly(schedule: AutomationSchedule.once(at(2026, 9, 9, 3))));
      clock.now = at(2026, 9, 9, 9);
      await scheduler().reconcile();
      expect(dao.runsFor('auto1').single.state, AutomationRunState.missed);
      expect(dao.getById('auto1')!.enabled, isFalse);
    });

    test('a one-shot that fired is over too, and keeps its row', () async {
      dao.insert(nightly(schedule: AutomationSchedule.once(at(2026, 9, 9, 3))));
      clock.now = at(2026, 9, 9, 3, 5);
      await scheduler().reconcile();
      expect(firing.fired, hasLength(1));
      expect(dao.getById('auto1')!.enabled, isFalse);
      expect(dao.getById('auto1'), isNotNull);
    });

    test('the boot sweep runs once, on its own, without being asked', () async {
      dao.insert(nightly());
      clock.now = at(2026, 9, 9, 9);
      scheduler();
      // Deferred so arming happens first; a microtask is all it waits for.
      await Future<void>.delayed(Duration.zero);
      expect(dao.runsFor('auto1').single.state, AutomationRunState.missed);
    });
  });

  group('a busy checkout queues, it does not race', () {
    test(
      'a fire arriving while a run is live is enqueued, and says so',
      () async {
        dao.insert(nightly(id: 'first', name: 'First'));
        dao.insert(
          nightly(
            id: 'second',
            name: 'Second',
            schedule: const AutomationSchedule.cron('5 3 * * *'),
          ),
        );
        clock.now = at(2026, 9, 9, 3, 2);
        await scheduler().reconcile();
        expect(firing.fired.single.automationId, 'first');

        clock.now = at(2026, 9, 9, 3, 6);
        await scheduler().reconcile();
        expect(firing.fired, hasLength(1), reason: 'the second did not start');
        final queued = dao.runsFor('second').single;
        expect(queued.state, AutomationRunState.queued);
        expect(queued.scheduledFor, at(2026, 9, 9, 3, 5).toUtc());
        expect(queued.reason, contains('This checkout is busy'));
        expect(queued.reason, contains('"First" is running there'));
      },
    );

    test('another checkout is not blocked by it', () async {
      dao.insert(nightly(id: 'first'));
      dao.insert(nightly(id: 'elsewhere', repositoryId: 'r2'));
      clock.now = at(2026, 9, 9, 3, 2);
      await scheduler().reconcile();
      // Both start; the order between two free checkouts is not a rule.
      expect(
        firing.fired.map((f) => f.automationId),
        unorderedEquals(['first', 'elsewhere']),
      );
    });

    test(
      'draining starts the waiting run in place, not a second row',
      () async {
        dao.insert(nightly(id: 'first', name: 'First'));
        dao.insert(
          nightly(
            id: 'second',
            name: 'Second',
            schedule: const AutomationSchedule.cron('5 3 * * *'),
          ),
        );
        clock.now = at(2026, 9, 9, 3, 2);
        await scheduler().reconcile();
        clock.now = at(2026, 9, 9, 3, 6);
        await scheduler().reconcile();

        // The owner finishes.
        final owner = dao.runsFor('first').single;
        dao.updateRun(owner.copyWith(state: AutomationRunState.finished));
        await scheduler().drain('r1');

        expect(firing.fired.last.automationId, 'second');
        final runs = dao.runsFor('second');
        expect(runs, hasLength(1), reason: 'the waiting row became the run');
        expect(runs.single.state, AutomationRunState.running);
      },
    );

    test('draining a checkout that is still busy starts nothing', () async {
      dao.insert(nightly(id: 'first', name: 'First'));
      dao.insert(
        nightly(
          id: 'second',
          name: 'Second',
          schedule: const AutomationSchedule.cron('5 3 * * *'),
        ),
      );
      clock.now = at(2026, 9, 9, 3, 2);
      await scheduler().reconcile();
      clock.now = at(2026, 9, 9, 3, 6);
      await scheduler().reconcile();
      await scheduler().drain('r1');
      expect(firing.fired, hasLength(1));
    });

    test('a run still queued is not jumped by a later occurrence', () async {
      dao.insert(nightly(id: 'first', name: 'First'));
      dao.insert(
        nightly(
          id: 'second',
          name: 'Second',
          schedule: const AutomationSchedule.cron('5 * * * *'),
        ),
      );
      clock.now = at(2026, 9, 9, 3, 2);
      await scheduler().reconcile();
      clock.now = at(2026, 9, 9, 3, 6);
      await scheduler().reconcile();
      clock.now = at(2026, 9, 9, 4, 6);
      await scheduler().reconcile();
      expect(firing.fired, hasLength(1));
      final queued = dao
          .runsFor('second')
          .where((r) => r.state == AutomationRunState.queued)
          .toList();
      // One waiting occurrence, not two: a second of the *same* automation
      // behind the first would run the same prompt twice back to back.
      expect(queued, hasLength(1));
      expect(queued.single.reason, contains('This checkout is busy'));
      // And the one that was not queued behind it is recorded rather than
      // dropped — beside the genuinely-missed occurrence from before any of
      // this was running, which is a different row for a different reason.
      final skipped = dao
          .runsFor('second')
          .where(
            (r) =>
                r.state == AutomationRunState.missed &&
                r.reason.contains('already had the occurrence due'),
          )
          .toList();
      expect(skipped, hasLength(1));
      // FIFO: the drain takes the oldest occurrence, not the newest.
      final owner = dao.runsFor('first').last;
      dao.updateRun(owner.copyWith(state: AutomationRunState.finished));
      await scheduler().drain('r1');
      expect(firing.fired.last.scheduledFor, at(2026, 9, 9, 3, 5).toUtc());
    });
  });
}
