import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_scheduler.dart';
import 'package:karmashala/src/features/automations/application/automation_timer.dart';
import 'package:karmashala_automations/persistence.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/schedules.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala_core/util.dart';
import 'package:karmashala_store/database.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

class _MovableClock implements Clock {
  _MovableClock(this.now);
  DateTime now;
  @override
  DateTime nowUtc() => now.toUtc();
}

/// Records fires without starting anything, leaving the run where it is told.
class _Firing implements AutomationFiring {
  _Firing(this._dao, this._clock);

  final AutomationDao _dao;
  final _MovableClock _clock;
  final fired = <DateTime>[];
  AutomationRunState settleAs = AutomationRunState.running;
  var _next = 0;

  @override
  Future<void> fire(
    Automation automation,
    DateTime scheduledFor, {
    String note = '',
    AutomationRun? queued,
  }) async {
    fired.add(scheduledFor);
    final run = AutomationRun(
      id: 'fired-${_next++}',
      automationId: automation.id,
      scheduledFor: scheduledFor,
      firedAt: _clock.nowUtc(),
      state: settleAs,
      reason: note,
      finishedAt: settleAs == AutomationRunState.running
          ? null
          : _clock.nowUtc(),
    );
    if (queued != null) {
      _dao.updateRun(
        queued.copyWith(state: run.state, finishedAt: run.finishedAt),
      );
      return;
    }
    _dao.insertRun(run);
  }
}

/// **An interval is not sugar over cron.** Its gap is measured from the end of
/// one run to the start of the next, which is the only way an unattended
/// recurring run can be left alone without stacking on itself.
void main() {
  late AppDatabase db;
  late AutomationDao dao;
  late _MovableClock clock;
  late ManualAutomationTimer timer;
  late _Firing firing;
  late ProviderContainer container;

  DateTime at(int y, int m, int d, [int h = 0, int min = 0]) =>
      DateTime(y, m, d, h, min);

  Automation every({
    Duration gap = const Duration(hours: 1),
    String id = 'auto1',
    DateTime? armedAt,
    AutomationLatePolicy latePolicy = AutomationLatePolicy.ask,
    Duration? maxRuntime,
    int stopAfterFailures = kDefaultStopAfterFailures,
  }) => Automation(
    id: id,
    repositoryId: 'r1',
    name: 'Sweep',
    schedule: AutomationSchedule.every(gap),
    agentInstallationId: 'a1',
    prompt: 'Run the checks.',
    permissionMode: null,
    enabled: true,
    armedAt: armedAt ?? at(2026, 9, 8, 17),
    latePolicy: latePolicy,
    maxRuntime: maxRuntime,
    stopAfterFailures: stopAfterFailures,
  );

  AutomationScheduler scheduler() {
    container.listen(automationSchedulerProvider, (_, _) {});
    return container.read(automationSchedulerProvider.notifier);
  }

  setUp(() {
    db = AppDatabase.memory();
    ExecutionEnvironmentDao(db).upsert(windowsEnv());
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    dao = AutomationDao(db);
    clock = _MovableClock(at(2026, 9, 8, 17));
    timer = ManualAutomationTimer();
    firing = _Firing(dao, clock);
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

  group('the schedule itself', () {
    test('round-trips through the database', () {
      dao.insert(every(gap: const Duration(minutes: 90)));
      final read = dao.getById('auto1')!;
      expect(read.schedule.isInterval, isTrue);
      expect(read.schedule.gap, const Duration(minutes: 90));
      expect(read.schedule.isRecurring, isTrue);
      expect(read.schedule.isOnce, isFalse);
    });

    test('refuses to be shorter than the floor', () {
      // Below this the next run is due before the last could have finished,
      // and the queue quietly becomes the schedule.
      expect(
        AutomationSchedule.every(const Duration(seconds: 5)).gap,
        kMinimumInterval,
      );
    });

    test('describes itself in the shortest true spelling', () {
      expect(describeGap(const Duration(minutes: 45)), '45m');
      expect(describeGap(const Duration(hours: 2)), '2h');
      expect(describeGap(const Duration(minutes: 90)), '1h30m');
    });
  });

  group('when it is next due', () {
    test('counts from the arming before it has ever run', () {
      dao.insert(every(gap: const Duration(hours: 2)));
      scheduler();
      expect(timer.armedFor, const Duration(hours: 2));
    });

    test('counts from the last run\'s finish, not from its occurrence', () {
      dao.insert(every(gap: const Duration(hours: 1)));
      // A run that took two hours: due an hour after it *ended*, at 21:00.
      dao.insertRun(
        AutomationRun(
          id: 'r',
          automationId: 'auto1',
          scheduledFor: at(2026, 9, 8, 18).toUtc(),
          firedAt: at(2026, 9, 8, 18).toUtc(),
          state: AutomationRunState.finished,
          reason: '',
          finishedAt: at(2026, 9, 8, 20).toUtc(),
        ),
      );
      clock.now = at(2026, 9, 8, 20);
      scheduler();
      expect(timer.armedFor, const Duration(hours: 1));
    });

    test('a run still going has no next occurrence at all', () {
      // The whole point: nothing is due while the last one has not finished,
      // so an interval cannot stack on itself even without a queue.
      dao.insert(every(gap: const Duration(minutes: 1)));
      dao.insertRun(
        AutomationRun(
          id: 'r',
          automationId: 'auto1',
          scheduledFor: at(2026, 9, 8, 18).toUtc(),
          firedAt: at(2026, 9, 8, 18).toUtc(),
          state: AutomationRunState.running,
          reason: '',
        ),
      );
      clock.now = at(2026, 9, 8, 23);
      scheduler();
      expect(timer.isArmed, isFalse);
    });
  });

  group('firing', () {
    test('runs once the gap has passed, and not before', () async {
      dao.insert(every(gap: const Duration(hours: 2)));
      firing.settleAs = AutomationRunState.finished;

      clock.now = at(2026, 9, 8, 18);
      await scheduler().reconcile();
      expect(firing.fired, isEmpty, reason: 'only an hour has passed');

      clock.now = at(2026, 9, 8, 19, 1);
      await scheduler().reconcile();
      expect(firing.fired, hasLength(1));
    });

    test(
      'a long sleep is one run due now, not one per gap slept through',
      () async {
        // Sixty missed ten-minute gaps is one run's worth of work, not sixty.
        // Running sixty would be catching up on time, not on anything.
        dao.insert(
          every(
            gap: const Duration(minutes: 10),
            latePolicy: AutomationLatePolicy.run,
          ),
        );
        firing.settleAs = AutomationRunState.finished;
        clock.now = at(2026, 9, 9, 3);
        await scheduler().reconcile();
        expect(firing.fired, hasLength(1));
      },
    );

    test('beyond the grace it is a recorded miss, not a silent one', () async {
      dao.insert(every(gap: const Duration(minutes: 10)));
      clock.now = at(2026, 9, 9, 3);
      await scheduler().reconcile();
      // Default policy: too late to run, so it says so instead.
      final runs = dao.runsFor('auto1');
      expect(firing.fired, isEmpty);
      expect(runs, isNotEmpty);
      expect(runs.every((r) => r.state == AutomationRunState.missed), isTrue);
      expect(runs.every((r) => r.reason.isNotEmpty), isTrue);
      // And the same occurrence is not filed again on the next tick.
      final before = runs.length;
      await scheduler().reconcile();
      expect(dao.runsFor('auto1'), hasLength(before));
    });

    test('"run it however late" runs it anyway', () async {
      dao.insert(
        every(
          gap: const Duration(minutes: 10),
          latePolicy: AutomationLatePolicy.run,
        ),
      );
      firing.settleAs = AutomationRunState.finished;
      clock.now = at(2026, 9, 9, 3);
      await scheduler().reconcile();
      expect(firing.fired, hasLength(1));
    });

    test('"skip it" records one that fell due before the app was up, however '
        'fresh', () async {
      dao.insert(
        every(
          gap: const Duration(minutes: 10),
          latePolicy: AutomationLatePolicy.skip,
        ),
      );
      // Started 30 s after it fell due: inside any tick latency, but the app
      // was not running at 17:10, so that occurrence was downtime.
      clock.now = at(2026, 9, 8, 17, 10).add(const Duration(seconds: 30));
      await scheduler().reconcile();
      expect(firing.fired, isEmpty);
      expect(dao.runsFor('auto1'), isNotEmpty);
      expect(
        dao.runsFor('auto1').every((r) => r.state == AutomationRunState.missed),
        isTrue,
      );
    });

    group('"skip it" does not charge tick latency as downtime', () {
      Future<AutomationScheduler> awakeSince1700() async {
        dao.insert(
          every(
            gap: const Duration(minutes: 10),
            latePolicy: AutomationLatePolicy.skip,
          ),
        );
        final s = scheduler();
        await Future<void>.delayed(Duration.zero);
        return s;
      }

      test('an occurrence the app was up for runs, though the tick lands '
          'late', () async {
        final s = await awakeSince1700();
        clock.now = at(
          2026,
          9,
          8,
          17,
          10,
        ).add(const Duration(milliseconds: 40));
        await s.reconcile();
        expect(
          firing.fired.single.isAtSameMomentAs(at(2026, 9, 8, 17, 10)),
          isTrue,
        );
        expect(
          dao
              .runsFor('auto1')
              .where((r) => r.state == AutomationRunState.missed),
          isEmpty,
        );
      });

      test('a tick hours late — a suspend — is still a miss', () async {
        final s = await awakeSince1700();
        clock.now = at(2026, 9, 9, 1);
        await s.reconcile();
        expect(firing.fired, isEmpty);
        expect(dao.runsFor('auto1').single.state, AutomationRunState.missed);
      });
    });
  });

  group('a run that will not end', () {
    test(
      'is failed at its ceiling, and says the agent was left alone',
      () async {
        dao.insert(
          every(
            gap: const Duration(hours: 1),
            maxRuntime: const Duration(hours: 2),
          ),
        );
        dao.insertRun(
          AutomationRun(
            id: 'hung',
            automationId: 'auto1',
            scheduledFor: at(2026, 9, 8, 18).toUtc(),
            firedAt: at(2026, 9, 8, 18).toUtc(),
            state: AutomationRunState.running,
            reason: '',
          ),
        );
        clock.now = at(2026, 9, 8, 21);
        await scheduler().reconcile();

        final run = dao.runsFor('auto1').firstWhere((r) => r.id == 'hung');
        expect(run.state, AutomationRunState.failed);
        expect(run.reason, contains('past the 2h this automation allows'));
        // Killing a PTY mid-edit is worse than a late run, so it is not done —
        // and the row must not read as though it were.
        expect(run.reason, contains('agent itself was not stopped'));
      },
    );

    test('is left alone while it is still inside its ceiling', () async {
      dao.insert(
        every(
          gap: const Duration(hours: 1),
          maxRuntime: const Duration(hours: 4),
        ),
      );
      dao.insertRun(
        AutomationRun(
          id: 'slow',
          automationId: 'auto1',
          scheduledFor: at(2026, 9, 8, 18).toUtc(),
          firedAt: at(2026, 9, 8, 18).toUtc(),
          state: AutomationRunState.running,
          reason: '',
        ),
      );
      clock.now = at(2026, 9, 8, 21);
      await scheduler().reconcile();
      expect(dao.runsFor('auto1').single.state, AutomationRunState.running);
    });

    test('no ceiling means no ceiling, however long it holds', () async {
      dao.insert(every(gap: const Duration(hours: 1)));
      dao.insertRun(
        AutomationRun(
          id: 'forever',
          automationId: 'auto1',
          scheduledFor: at(2026, 9, 8, 18).toUtc(),
          firedAt: at(2026, 9, 8, 18).toUtc(),
          state: AutomationRunState.running,
          reason: '',
        ),
      );
      clock.now = at(2026, 9, 20);
      await scheduler().reconcile();
      expect(
        dao.runsFor('auto1').firstWhere((r) => r.id == 'forever').state,
        AutomationRunState.running,
      );
    });

    test('its ceiling is a moment the timer waits for', () {
      dao.insert(
        every(
          gap: const Duration(days: 1),
          maxRuntime: const Duration(hours: 2),
        ),
      );
      dao.insertRun(
        AutomationRun(
          id: 'hung',
          automationId: 'auto1',
          scheduledFor: at(2026, 9, 8, 17).toUtc(),
          firedAt: at(2026, 9, 8, 17).toUtc(),
          state: AutomationRunState.running,
          reason: '',
        ),
      );
      scheduler();
      // Without this the timer would sleep until the next occurrence, which a
      // held checkout guarantees never comes.
      expect(timer.armedFor, const Duration(hours: 2));
    });
  });

  group('the failure budget', () {
    test('counts failures and clears on any success', () {
      dao.insert(every());
      dao.recordOutcome('auto1', failed: true);
      dao.recordOutcome('auto1', failed: true);
      expect(dao.getById('auto1')!.consecutiveFailures, 2);
      dao.recordOutcome('auto1', failed: false);
      expect(dao.getById('auto1')!.consecutiveFailures, 0);
    });

    test('says when it has been spent', () {
      dao.insert(every(stopAfterFailures: 2));
      dao.recordOutcome('auto1', failed: true);
      expect(dao.getById('auto1')!.hasFailedOut, isFalse);
      dao.recordOutcome('auto1', failed: true);
      expect(dao.getById('auto1')!.hasFailedOut, isTrue);
    });

    test('a budget of zero never spends, which is how you opt out', () {
      dao.insert(every(stopAfterFailures: 0));
      for (var i = 0; i < 20; i++) {
        dao.recordOutcome('auto1', failed: true);
      }
      expect(dao.getById('auto1')!.hasFailedOut, isFalse);
    });

    test('disabling says why, and a success clears that too', () {
      dao.insert(every());
      dao.disable('auto1', 'Stopped after 3 failed runs in a row.');
      final stopped = dao.getById('auto1')!;
      expect(stopped.enabled, isFalse);
      expect(stopped.disabledReason, contains('3 failed runs'));

      // Re-enabled and fixed: it must not start one failure from stopping.
      dao.recordOutcome('auto1', failed: false);
      expect(dao.getById('auto1')!.disabledReason, isNull);
    });
  });

  group('missedFireDecision for an interval', () {
    test('is not due before the gap has passed', () {
      expect(
        missedFireDecision(
          schedule: AutomationSchedule.every(const Duration(hours: 2)),
          since: at(2026, 9, 8, 17),
          now: at(2026, 9, 8, 18),
        ),
        isA<NoMissedFires>(),
      );
    });

    test('is one occurrence however long the sleep', () {
      final decision = missedFireDecision(
        schedule: AutomationSchedule.every(const Duration(minutes: 10)),
        since: at(2026, 9, 8, 17),
        now: at(2026, 9, 9, 17),
      );
      expect(decision, isA<MissedFires>());
      expect((decision as MissedFires).missedCount, 1);
      expect(decision.capped, isFalse);
    });
  });
}
